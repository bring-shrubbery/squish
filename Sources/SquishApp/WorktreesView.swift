import AppKit
import SquishCore
import SwiftUI

struct WorktreesView: View {
    @EnvironmentObject private var store: WorktreeStore
    // The presented values are kept after dismissal (only the flags reset), so an alert's
    // title and message never go blank while it animates out.
    @State private var confirmation: Confirmation?
    @State private var isConfirming = false
    @State private var anyway: Anyway?
    @State private var isConfirmingAnyway = false
    @State private var skippedAfterBulk: [Worktree] = []

    /// A worktree with work in it and the counts the user saw; removal refuses if git
    /// reports more by the time it runs.
    private struct LossTarget {
        let worktree: Worktree
        let uncommitted: Int
        let unpushed: Int
    }

    private enum Confirmation {
        case remove(Worktree)
        case losingWork(Worktree, uncommitted: Int, unpushed: Int, detached: Bool)
        case bulk(WorktreeBulkPlan)
    }

    /// The second confirmation for losing work.
    private enum Anyway {
        case single(LossTarget)
        case bulk(WorktreeBulkPlan)
    }

    private enum CheckState {
        case off, on, mixed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    PageHeader(
                        eyebrow: "Disk hygiene",
                        title: "Worktrees",
                        subtitle: "Linked git worktrees of the repos in your folder. Filter, select, remove."
                    )
                    Spacer()
                    Button {
                        skippedAfterBulk = []
                        store.refresh()
                    } label: {
                        Label(store.isRefreshing ? "Scanning…" : "Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isRefreshing)
                }

                summary
                filterBar

                if store.gitUnavailable {
                    notice(
                        "git is not available",
                        "Squish uses git to find and remove worktrees. Install the command line tools with xcode-select --install, then refresh."
                    )
                } else if store.scans.allSatisfy({ $0.worktrees.isEmpty && $0.error == nil }) && !store.isRefreshing {
                    notice("No linked worktrees", "None of the repos in your folder has a linked worktree.")
                } else {
                    selectionBar
                    ForEach(store.scans) { scan in
                        repoCard(scan)
                    }
                }

                if !skippedAfterBulk.isEmpty {
                    notice(
                        "Skipped \(skippedAfterBulk.count)",
                        names(skippedAfterBulk)
                            + ". They are in use, locked or unreadable, changed since you confirmed, or git refused"
                            + " (the row says why). Remove these one at a time."
                    )
                }
            }
            .padding(28)
        }
        .onAppear {
            skippedAfterBulk = []
            store.refresh()
        }
        .alert(
            Text(confirmation.map(title(for:)) ?? ""),
            isPresented: $isConfirming,
            presenting: confirmation
        ) { confirmation in
            buttons(for: confirmation)
        } message: { confirmation in
            Text(message(for: confirmation))
        }
        // The second confirmation for losing work: its own alert, so presenting it cannot be
        // dropped while the first one is still animating out.
        .alert(
            Text(anyway.map(anywayTitle(for:)) ?? ""),
            isPresented: $isConfirmingAnyway,
            presenting: anyway
        ) { anyway in
            Button("Remove anyway", role: .destructive) {
                switch anyway {
                case .single(let target):
                    Task {
                        await store.remove(
                            target.worktree,
                            force: true,
                            confirmedUncommitted: target.uncommitted,
                            confirmedUnpushed: target.unpushed
                        )
                    }
                case .bulk(let plan):
                    runBulk(plan, losingWork: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { anyway in
            Text(anywayMessage(for: anyway))
        }
    }

    private func confirm(_ value: Confirmation) {
        confirmation = value
        isConfirming = true
    }

    private func confirmAnyway(_ value: Anyway) {
        anyway = value
        isConfirmingAnyway = true
    }

    private func runBulk(_ plan: WorktreeBulkPlan, losingWork: Bool) {
        Task {
            let skipped = await store.removePlanned(plan, losingWork: losingWork)
            skippedAfterBulk = skipped + plan.skipped.map(\.worktree)
        }
    }

    // MARK: - Header

    private var summary: some View {
        HStack(alignment: .center, spacing: 18) {
            stat("On disk", Self.bytes(store.totalBytes))
            stat("Flagged", "\(store.flaggedCount) · \(Self.bytes(store.flaggedBytes))")
            stat("Shown", "\(store.visibleWorktrees.count) of \(store.worktrees.count)")
            Divider().frame(height: 34)
            VStack(alignment: .leading, spacing: 6) {
                Text("FLAG WHEN")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Stepper(value: ageBinding, in: 1...365) {
                        Text("Older than \(store.thresholds.maxAgeDays) days")
                            .font(.system(size: 12, weight: .medium))
                    }
                    Stepper(value: sizeBinding, in: 1...200) {
                        Text("Larger than \(store.thresholds.maxSizeBytes / 1_000_000_000) GB")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
            }
            Spacer()
        }
        .padding(18)
        .appCard()
        .overlay(alignment: .bottomTrailing) {
            if let reclaimed = store.lastReclaimed, reclaimed > 0 {
                Text("Freed \(Self.bytes(reclaimed))")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(AppColors.mint.opacity(0.22), in: Capsule())
                    .padding(10)
            }
        }
    }

    private var ageBinding: Binding<Int> {
        Binding(
            get: { store.thresholds.maxAgeDays },
            set: { store.thresholds.maxAgeDays = $0 }
        )
    }

    private var sizeBinding: Binding<Int> {
        Binding(
            get: { Int(store.thresholds.maxSizeBytes / 1_000_000_000) },
            set: { store.thresholds.maxSizeBytes = Int64($0) * 1_000_000_000 }
        )
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .bold).monospacedDigit())
        }
    }

    // MARK: - Filters

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Branch or path", text: $store.filter.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 320)

                Picker("Sort", selection: $store.filter.sort) {
                    ForEach(WorktreeSort.allCases) { sort in
                        Text(Self.title(sort)).tag(sort)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()

                Spacer()

                if !store.filter.isDefault {
                    Button("Reset filters") { store.filter = WorktreeFilter() }
                        .controlSize(.small)
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10, alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                choice("Flagged", $store.filter.flagged)
                choice("In use", $store.filter.inUse)
                choice("Unsaved work", $store.filter.withWork)
                choice("Agent-made", $store.filter.agentMade)
                choice("Locked", $store.filter.locked)
                choice("Missing", $store.filter.missing)
                Picker("Size", selection: $store.filter.minSizeBytes) {
                    ForEach(WorktreeFilter.sizeSteps, id: \.self) { bytes in
                        Text(bytes == 0 ? "Any" : "At least \(Self.bytes(bytes))").tag(bytes)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                Picker("Idle", selection: $store.filter.minIdleDays) {
                    ForEach(WorktreeFilter.idleSteps, id: \.self) { days in
                        Text(days == 0 ? "Any" : "At least \(Self.idle(days))").tag(days)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
            }
        }
        .padding(18)
        .appCard()
    }

    private func choice(_ label: String, _ binding: Binding<WorktreeFilterChoice>) -> some View {
        Picker(label, selection: binding) {
            ForEach(WorktreeFilterChoice.allCases) { choice in
                Text(Self.title(choice)).tag(choice)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
    }

    private static func title(_ choice: WorktreeFilterChoice) -> String {
        switch choice {
        case .any: "Any"
        case .only: "Only"
        case .exclude: "Hide"
        }
    }

    private static func title(_ sort: WorktreeSort) -> String {
        switch sort {
        case .largest: "Largest first"
        case .oldest: "Oldest first"
        case .newest: "Newest first"
        case .name: "By name"
        }
    }

    private static func idle(_ days: Int) -> String {
        switch days {
        case 7: "a week"
        case 14: "2 weeks"
        case 30: "a month"
        case 90: "3 months"
        default: days == 1 ? "a day" : "\(days) days"
        }
    }

    // MARK: - Selection

    private var selectionBar: some View {
        let visible = store.visibleWorktrees
        let selectable = visible.filter(store.isSelectable)
        let selectedShown = visible.filter(store.isSelected)
        let count = store.selection.count
        return HStack(spacing: 14) {
            checkbox(
                checkState(selected: selectedShown.count, of: selectable.count),
                help: selectedShown.count == selectable.count && !selectable.isEmpty
                    ? "Deselect all shown" : "Select all shown"
            ) {
                if selectedShown.count == selectable.count, !selectable.isEmpty {
                    store.deselect(visible)
                } else {
                    store.select(visible)
                }
            }
            .disabled(selectable.isEmpty)

            Text(count == 0 ? "Nothing selected" : "\(count) selected · \(Self.bytes(store.selectedBytes))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
            if count > selectedShown.count {
                Text("(\(count - selectedShown.count) hidden by the filter)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu("Select") {
                Button("All shown") { store.select(visible) }
                    .disabled(selectable.isEmpty)
                Button("Flagged shown") { store.selectFlagged() }
                Button("None") { store.clearSelection() }
                    .disabled(count == 0)
            }
            .controlSize(.small)
            .fixedSize()

            Button(count == 0 ? "Remove selected" : "Remove \(count) selected") {
                confirm(.bulk(store.bulkPlan()))
            }
            .disabled(count == 0 || store.isRemoving)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .appCard()
    }

    private func checkState(selected: Int, of total: Int) -> CheckState {
        if selected == 0 { return .off }
        return selected == total ? .on : .mixed
    }

    private func checkbox(_ state: CheckState, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: state == .off ? "square" : state == .on ? "checkmark.square.fill" : "minus.square.fill")
                .font(.system(size: 15))
                .foregroundStyle(state == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(AppColors.mint))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Rows

    private func repoCard(_ scan: RepoScan) -> some View {
        let rows = store.visibleWorktrees(in: scan.repoPath)
        let selectable = rows.filter(store.isSelectable)
        let selected = rows.filter(store.isSelected)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                checkbox(
                    checkState(selected: selected.count, of: selectable.count),
                    help: "Select this repo's shown worktrees"
                ) {
                    if selected.count == selectable.count, !selectable.isEmpty {
                        store.deselect(rows)
                    } else {
                        store.select(rows)
                    }
                }
                .disabled(selectable.isEmpty)
                Text(URL(fileURLWithPath: scan.repoPath).lastPathComponent)
                    .font(.system(size: 14, weight: .bold))
                Text(scan.repoPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if scan.worktrees.count > rows.count {
                    Text("\(scan.worktrees.count - rows.count) hidden")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 10)

            if let error = scan.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.coral)
            } else if rows.isEmpty {
                Text(scan.worktrees.isEmpty ? "No linked worktrees." : "Nothing matches the filter.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ForEach(rows) { worktree in
                row(worktree)
                if worktree.id != rows.last?.id {
                    Divider().overlay(.white.opacity(0.04))
                }
            }
        }
        .padding(18)
        .appCard()
    }

    private func row(_ worktree: Worktree) -> some View {
        let flags = store.flags(for: worktree)
        let selected = store.isSelected(worktree)
        let selectable = store.isSelectable(worktree)
        return HStack(alignment: .center, spacing: 14) {
            checkbox(
                selected ? .on : .off,
                help: selectable ? (selected ? "Deselect" : "Select") : blockedReason(worktree)
            ) {
                store.setSelected(worktree, !selected)
            }
            .disabled(!selectable)
            .opacity(selectable ? 1 : 0.35)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(worktree.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    if let agent = worktree.agent {
                        chip(agent.rawValue, AppColors.violet)
                    }
                    if worktree.uncommittedCount > 0 { chip("Uncommitted changes", AppColors.amber) }
                    if worktree.unpushedCount > 0 { chip("Unpushed commits", AppColors.amber) }
                    if store.isInUse(worktree) { chip("In use", AppColors.mint) }
                    if worktree.isLocked { chip("Locked", .secondary) }
                    if worktree.isPrunable { chip("Missing", AppColors.coral) }
                    ForEach(flagLabels(flags), id: \.self) { label in
                        chip(label, AppColors.amber)
                    }
                }
                Text(worktree.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detailError = worktree.detailError {
                    Text("Couldn't read details: \(detailError)")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.coral)
                }
                if let error = store.rowErrors[worktree.path] {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.coral)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(sizeText(worktree))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(flags.contains { if case .size = $0 { true } else { false } } ? AppColors.amber : .primary)
                Text(activityText(worktree))
                    .font(.system(size: 11))
                    .foregroundStyle(flags.contains { if case .age = $0 { true } else { false } } ? AppColors.amber : .secondary)
            }
            .frame(width: 110, alignment: .trailing)
            actions(worktree)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? AppColors.mint.opacity(0.10) : flags.isEmpty ? .clear : AppColors.amber.opacity(0.07))
        )
    }

    private func blockedReason(_ worktree: Worktree) -> String {
        if case .blocked(let reason) = store.removal(for: worktree) { return reason }
        return ""
    }

    private func actions(_ worktree: Worktree) -> some View {
        HStack(spacing: 6) {
            if !worktree.isPrunable {
                iconButton("folder", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)])
                }
                iconButton("terminal", help: "Open in Terminal") {
                    openInTerminal(worktree.path)
                }
            }
            removeButton(worktree)
        }
    }

    @ViewBuilder
    private func removeButton(_ worktree: Worktree) -> some View {
        switch store.removal(for: worktree) {
        case .confirm:
            Button("Remove") { confirm(.remove(worktree)) }
                .disabled(store.isRemoving)
        case let .confirmLosingWork(uncommitted, unpushed, detached):
            Button("Remove") {
                confirm(.losingWork(worktree, uncommitted: uncommitted, unpushed: unpushed, detached: detached))
            }
            .disabled(store.isRemoving)
        case .blocked(let reason):
            Button("Remove") {}
                .disabled(true)
                .help(reason)
        case .pruneOnly:
            Button("Prune") { Task { await store.prune(worktree) } }
                .disabled(store.isRemoving)
                .help("The directory is gone; remove git's record of it.")
        }
    }

    // MARK: - Confirmations

    private func title(for confirmation: Confirmation) -> String {
        switch confirmation {
        case .remove(let worktree):
            "Remove \(worktree.displayName)\(sizeSuffix(worktree))?"
        case .losingWork(let worktree, _, _, _):
            "\(worktree.displayName) has work that exists nowhere else"
        case .bulk(let plan):
            plan.isEmpty
                ? "Nothing selected can be removed"
                : "Remove \(plan.acted.count) \(plan.acted.count == 1 ? "worktree" : "worktrees") (\(Self.bytes(plan.bytes)))?"
        }
    }

    private func message(for confirmation: Confirmation) -> String {
        switch confirmation {
        case .remove(let worktree):
            branchKeptText(worktree)
        case let .losingWork(worktree, uncommitted, unpushed, detached):
            lossText(worktree, uncommitted: uncommitted, unpushed: unpushed, detached: detached)
        case .bulk(let plan):
            bulkText(plan)
        }
    }

    private func bulkText(_ plan: WorktreeBulkPlan) -> String {
        var parts: [String] = []
        if !plan.clean.isEmpty {
            parts.append("\(names(plan.clean)): removed; their branches are kept.")
        }
        if !plan.prune.isEmpty {
            parts.append("\(names(plan.prune)): the directory is already gone, so only git's record is removed.")
        }
        if !plan.losingWork.isEmpty {
            let count = plan.losingWork.count
            parts.append(
                "\(names(plan.losingWork.map(\.worktree))): \(count == 1 ? "has" : "have") work that exists nowhere else."
                    + " Removing \(count == 1 ? "it" : "them") too asks you to confirm what is lost."
            )
        }
        if !plan.skipped.isEmpty {
            parts.append(
                "\(names(plan.skipped.map(\.worktree))) will be skipped: in use, locked, or unreadable."
            )
        }
        return parts.joined(separator: "\n\n")
    }

    @ViewBuilder
    private func buttons(for confirmation: Confirmation) -> some View {
        switch confirmation {
        case .remove(let worktree):
            Button("Remove", role: .destructive) { Task { await store.remove(worktree, force: false) } }
        case let .losingWork(worktree, uncommitted, unpushed, _):
            Button("Continue…", role: .destructive) {
                confirmAnyway(.single(LossTarget(worktree: worktree, uncommitted: uncommitted, unpushed: unpushed)))
            }
        case .bulk(let plan):
            let safe = plan.clean.count + plan.prune.count
            if safe > 0 {
                Button(plan.losingWork.isEmpty ? "Remove" : "Remove \(safe) without work", role: .destructive) {
                    runBulk(plan, losingWork: false)
                }
            }
            if !plan.losingWork.isEmpty {
                Button(safe > 0 ? "Remove all \(plan.acted.count)…" : "Continue…", role: .destructive) {
                    confirmAnyway(.bulk(plan))
                }
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    private func anywayTitle(for anyway: Anyway) -> String {
        switch anyway {
        case .single(let target):
            return "Remove \(target.worktree.displayName) anyway?"
        case .bulk(let plan):
            let count = plan.losingWork.count
            return "Remove \(count) \(count == 1 ? "worktree" : "worktrees") with unsaved work anyway?"
        }
    }

    private func anywayMessage(for anyway: Anyway) -> String {
        switch anyway {
        case .single:
            return "This cannot be undone."
        case .bulk(let plan):
            return plan.losingWork.map { loss in
                "\(loss.worktree.displayName): "
                    + lossText(
                        loss.worktree, uncommitted: loss.uncommitted, unpushed: loss.unpushed, detached: loss.detached
                    )
            }
            .joined(separator: "\n") + "\n\nThis cannot be undone."
        }
    }

    private func branchKeptText(_ worktree: Worktree) -> String {
        if let branch = worktree.branch { return "The branch \(branch) is kept." }
        return "It is on a detached HEAD; nothing is lost because it has no unique commits."
    }

    private func lossText(_ worktree: Worktree, uncommitted: Int, unpushed: Int, detached: Bool) -> String {
        var lines: [String] = []
        if uncommitted > 0 {
            let changes = uncommitted == 1 ? "change (file or folder)" : "changes (files or folders)"
            lines.append("\(uncommitted) uncommitted \(changes) will be deleted.")
        }
        if unpushed > 0 {
            let commits = "\(unpushed) \(unpushed == 1 ? "commit is" : "commits are") on no remote or other branch"
            if detached {
                // git worktree remove deletes this worktree's HEAD reflog, so Squish saves them first.
                let branch = WorktreeRemover.rescueBranchBase(head: worktree.head)
                lines.append("\(commits); \(unpushed == 1 ? "it" : "they") will be saved on a new branch \(branch).")
            } else {
                lines.append("\(commits); \(unpushed == 1 ? "it stays" : "they stay") on branch \(worktree.branch ?? "").")
            }
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Helpers

    /// Up to eight names, then "and N more", so an alert stays readable.
    private func names(_ worktrees: [Worktree]) -> String {
        let shown = worktrees.prefix(8).map(\.displayName).joined(separator: ", ")
        let rest = worktrees.count - 8
        return rest > 0 ? "\(shown) and \(rest) more" : shown
    }

    private func flagLabels(_ flags: [WorktreeFlag]) -> [String] {
        flags.map { flag in
            switch flag {
            case .age: "Older than \(store.thresholds.maxAgeDays) days"
            case .size: "Larger than \(store.thresholds.maxSizeBytes / 1_000_000_000) GB"
            }
        }
    }

    private func sizeSuffix(_ worktree: Worktree) -> String {
        worktree.sizeBytes.map { " (\(Self.bytes($0)))" } ?? ""
    }

    private func sizeText(_ worktree: Worktree) -> String {
        if worktree.isPrunable { return "—" }
        if let bytes = worktree.sizeBytes { return Self.bytes(bytes) }
        return store.unmeasurable.contains(worktree.path) ? "—" : "Measuring…"
    }

    private func activityText(_ worktree: Worktree) -> String {
        guard let last = worktree.lastActivity else { return "No activity" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: last, relativeTo: Date())
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func notice(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14, weight: .bold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .appCard()
    }

    private func openInTerminal(_ path: String) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

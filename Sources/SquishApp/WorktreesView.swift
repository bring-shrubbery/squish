import AppKit
import SquishCore
import SwiftUI

struct WorktreesView: View {
    @EnvironmentObject private var store: WorktreeStore
    @State private var sortOrder = Self.comparators(for: WorktreeFilter().sort)
    @State private var isShowingFilters = false
    // The presented values are kept after dismissal (only the flags reset), so an alert's
    // title and message never go blank while it animates out.
    @State private var plan: WorktreeBulkPlan?
    @State private var isConfirming = false
    @State private var isConfirmingLoss = false
    @State private var failed: [Worktree] = []
    @State private var isShowingFailed = false

    var body: some View {
        let rows = store.visibleWorktrees
        VStack(spacing: 0) {
            if let notice = scanFailure {
                NoticeBar(text: notice, isError: true)
                Divider()
            }
            if store.filter.isNarrowed {
                NoticeBar(text: "Showing \(rows.count) of \(store.worktrees.count)") {
                    Button("Clear Filters") { clearFilters() }
                        .controlSize(.small)
                }
                Divider()
            }
            table(rows)
                .overlay { placeholder(rows) }
            Divider()
            statusBar
        }
        .navigationSubtitle(subtitle)
        .searchable(text: $store.filter.query, placement: .toolbar, prompt: "Branch or path")
        .toolbar { toolbar }
        .onAppear {
            sortOrder = Self.comparators(for: store.filter.sort)
            store.refresh()
        }
        .onChange(of: sortOrder) { _, comparators in
            if let sort = Self.sort(from: comparators) { store.filter.sort = sort }
        }
        .alert(
            Text(plan.map(title(for:)) ?? ""),
            isPresented: $isConfirming,
            presenting: plan
        ) { plan in
            buttons(for: plan)
        } message: { plan in
            Text(message(for: plan))
        }
        // The second confirmation for losing work: its own alert, so presenting it cannot be
        // dropped while the first one is still animating out.
        .alert(
            Text(plan.map(lossTitle(for:)) ?? ""),
            isPresented: $isConfirmingLoss,
            presenting: plan
        ) { plan in
            Button("Remove Anyway", role: .destructive) { run(plan, losingWork: true) }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(lossMessage(for: plan))
        }
        .alert(
            failed.count == 1 ? "\(failed[0].displayName) Couldn't Be Removed" : "Some Worktrees Couldn't Be Removed",
            isPresented: $isShowingFailed
        ) {
            Button("OK") {}
        } message: {
            Text(
                (failed.count == 1 ? "" : names(failed) + ". ")
                    + "The Status column says why. Each is still selected, so you can try again."
            )
        }
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                store.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
            .help("Scan the folder again")

            Button {
                isShowingFilters.toggle()
            } label: {
                Label(
                    "Filter",
                    systemImage: store.filter.isNarrowed
                        ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                )
            }
            .help("Filter the list and set when a worktree is flagged")
            .popover(isPresented: $isShowingFilters, arrowEdge: .bottom) {
                FilterPopover()
            }
        }
    }

    private var subtitle: String {
        let count = store.worktrees.count
        if store.isRefreshing, count == 0 { return "Scanning…" }
        let noun = count == 1 ? "1 worktree" : "\(count) worktrees"
        return count == 0 ? noun : "\(noun) · \(Self.bytes(store.totalBytes))"
    }

    private var scanFailure: String? {
        let failures = store.scans.compactMap { scan in
            scan.error.map { "Couldn't scan \(scan.repoName): \($0)" }
        }
        return failures.isEmpty ? nil : failures.joined(separator: "  ")
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer()
            if store.selection.isEmpty, store.flaggedCount > 0 {
                Button("Select Flagged") { store.selectFlagged() }
            }
            Button(removeTitle(count: store.selection.count)) {
                confirmRemoval(of: store.selection)
            }
            .disabled(store.selection.isEmpty || store.isRemoving)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var statusText: String {
        if let reclaimed = store.lastReclaimed, reclaimed > 0 { return "Freed \(Self.bytes(reclaimed))" }
        if store.isRemoving { return "Removing…" }
        let selected = store.selection.count
        if selected > 0 {
            return "\(selected) of \(store.worktrees.count) selected · \(Self.bytes(store.selectedBytes))"
        }
        let flagged = store.flaggedCount
        if flagged == 0 { return store.worktrees.isEmpty ? "" : "Nothing flagged" }
        return "\(flagged) flagged · \(Self.bytes(store.flaggedBytes))"
    }

    private func removeTitle(count: Int) -> String {
        count > 1 ? "Remove \(count)…" : "Remove…"
    }

    // MARK: - Table

    private func table(_ rows: [Worktree]) -> some View {
        Table(rows, selection: $store.selection, sortOrder: $sortOrder) {
            TableColumn("Branch", value: \.displayName) { worktree in
                nameCell(worktree)
            }
            .width(min: 180, ideal: 260)

            TableColumn("Repository", value: \.repoName) { worktree in
                Text(worktree.repoName)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 140)

            TableColumn("Status") { worktree in
                statusCell(worktree)
            }
            .width(min: 150, ideal: 260)

            TableColumn("Size", value: \.sizeForSort) { worktree in
                let size = sizeText(worktree)
                Text(size.text)
                    .monospacedDigit()
                    .foregroundStyle(size.isPending ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 76, ideal: 88)
            .alignment(.trailing)

            TableColumn("Last Active", value: \.activityForSort) { worktree in
                Text(activityText(worktree))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 100, ideal: 124)
            .alignment(.trailing)
        }
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            reveal(ids)
        }
        .onDeleteCommand {
            confirmRemoval(of: store.selection)
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugSnapshots.filtersNotification)) { _ in
            isShowingFilters.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: DebugSnapshots.removeNotification)) { _ in
            confirmRemoval(of: store.selection)
        }
        #endif
    }

    private func nameCell(_ worktree: Worktree) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(worktree.displayName)
                    .lineLimit(1)
                if let agent = worktree.agent {
                    Text(agent.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            Text((worktree.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    private struct StatusItem {
        var text: String
        var color: Color = .secondary
        var symbol: String?
        var symbolColor: Color?
    }

    private func statusItems(_ worktree: Worktree) -> [StatusItem] {
        var items: [StatusItem] = []
        if let error = store.rowErrors[worktree.path] {
            items.append(StatusItem(text: error, color: .red))
        }
        if let error = worktree.detailError {
            items.append(StatusItem(text: "Couldn't read details: \(error)", color: .red))
        }
        if worktree.isPrunable {
            items.append(StatusItem(text: "Missing", symbol: "questionmark.folder"))
        }
        if store.isInUse(worktree) {
            items.append(StatusItem(text: "In use", color: .primary, symbol: "circle.fill", symbolColor: .green))
        }
        if worktree.uncommittedCount > 0 {
            let count = worktree.uncommittedCount
            items.append(StatusItem(text: count == 1 ? "1 uncommitted change" : "\(count) uncommitted changes"))
        }
        if worktree.unpushedCount > 0 {
            let count = worktree.unpushedCount
            items.append(StatusItem(text: count == 1 ? "1 unpushed commit" : "\(count) unpushed commits"))
        }
        if worktree.isLocked {
            items.append(StatusItem(text: "Locked", symbol: "lock.fill"))
        }
        for flag in store.flags(for: worktree) {
            switch flag {
            case .age(let days):
                items.append(StatusItem(text: "Idle \(days) days", color: .orange))
            case .size:
                items.append(StatusItem(text: "Over \(store.thresholds.maxSizeBytes / 1_000_000_000) GB", color: .orange))
            }
        }
        return items
    }

    private func statusCell(_ worktree: Worktree) -> some View {
        let items = statusItems(worktree)
        return HStack(spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Text("·").foregroundStyle(.tertiary)
                }
                HStack(spacing: 4) {
                    if let symbol = item.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: item.symbol == "circle.fill" ? 7 : 10))
                            .foregroundStyle(item.symbolColor ?? item.color)
                    }
                    Text(item.text)
                        .foregroundStyle(item.color)
                }
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .help(items.map(\.text).joined(separator: "\n"))
    }

    @ViewBuilder
    private func placeholder(_ rows: [Worktree]) -> some View {
        if store.gitUnavailable {
            ContentUnavailableView {
                Label("Git Isn't Available", systemImage: "terminal")
            } description: {
                Text("Squish uses git to find and remove worktrees. Install the Command Line Tools with xcode-select --install, then refresh.")
            }
        } else if store.worktrees.isEmpty {
            if store.isRefreshing {
                ProgressView()
            } else if scanFailure == nil {
                ContentUnavailableView(
                    "No Worktrees",
                    systemImage: "arrow.triangle.branch",
                    description: Text("None of the repositories in this folder has a linked worktree.")
                )
            }
        } else if rows.isEmpty {
            let query = store.filter.query.trimmingCharacters(in: .whitespaces)
            if query.isEmpty {
                ContentUnavailableView {
                    Label("No Matches", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No worktree matches the current filters.")
                } actions: {
                    Button("Clear Filters") { clearFilters() }
                }
            } else {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        let targets = ids.compactMap(store.worktree(at:))
        let present = targets.filter { !$0.isPrunable }
        Button("Reveal in Finder") { reveal(ids) }
            .disabled(present.isEmpty)
        Button("Open in Terminal") {
            for worktree in present { openInTerminal(worktree.path) }
        }
        .disabled(present.isEmpty)
        Divider()
        Button(present.isEmpty && !targets.isEmpty ? "Prune" : removeTitle(count: targets.count)) {
            confirmRemoval(of: ids)
        }
        .disabled(targets.isEmpty || store.isRemoving)
    }

    private func reveal(_ ids: Set<String>) {
        let urls = ids.compactMap(store.worktree(at:)).filter { !$0.isPrunable }.map { URL(fileURLWithPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    private func clearFilters() {
        var cleared = WorktreeFilter()
        cleared.query = store.filter.query
        cleared.sort = store.filter.sort
        store.filter = cleared
    }

    // MARK: - Removal

    private func confirmRemoval(of ids: Set<String>) {
        guard !ids.isEmpty, !store.isRemoving else { return }
        plan = store.bulkPlan(for: ids)
        isConfirming = true
    }

    private func run(_ plan: WorktreeBulkPlan, losingWork: Bool) {
        Task {
            let skipped = await store.removePlanned(plan, losingWork: losingWork)
            if !skipped.isEmpty {
                failed = skipped
                isShowingFailed = true
            }
        }
    }

    /// A plan that acts on one worktree and skips none reads like a single removal.
    private func single(_ plan: WorktreeBulkPlan) -> Worktree? {
        plan.acted.count == 1 && plan.skipped.isEmpty ? plan.acted[0] : nil
    }

    private func title(for plan: WorktreeBulkPlan) -> String {
        if plan.isEmpty {
            return plan.skipped.count == 1
                ? "\(plan.skipped[0].worktree.displayName) can't be removed right now"
                : "None of the selected worktrees can be removed right now"
        }
        if let worktree = single(plan) {
            if !plan.losingWork.isEmpty { return "\(worktree.displayName) has work that exists nowhere else" }
            if !plan.prune.isEmpty { return "Prune \(worktree.displayName)?" }
            return "Remove \(worktree.displayName)\(sizeSuffix(worktree))?"
        }
        let count = plan.acted.count
        return "Remove \(count) \(count == 1 ? "worktree" : "worktrees") (\(Self.bytes(plan.bytes)))?"
    }

    private func message(for plan: WorktreeBulkPlan) -> String {
        if plan.isEmpty {
            return plan.skipped.map { "\($0.worktree.displayName): \($0.reason)" }.joined(separator: "\n")
        }
        if let worktree = single(plan) {
            if let loss = plan.losingWork.first {
                return lossText(worktree, uncommitted: loss.uncommitted, unpushed: loss.unpushed, detached: loss.detached)
            }
            if !plan.prune.isEmpty { return "The directory is already gone, so only git's record of it is removed." }
            return branchKeptText(worktree)
        }
        var parts: [String] = []
        if !plan.clean.isEmpty {
            parts.append("\(names(plan.clean)): removed; the branches are kept.")
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
            let reasons = plan.skipped.prefix(8).map { "\($0.worktree.displayName): \($0.reason)" }
            let rest = plan.skipped.count - 8
            parts.append(
                "Skipped:\n" + reasons.joined(separator: "\n")
                    + (rest > 0 ? "\nand \(rest) more" : "")
            )
        }
        return parts.joined(separator: "\n\n")
    }

    @ViewBuilder
    private func buttons(for plan: WorktreeBulkPlan) -> some View {
        if plan.isEmpty {
            Button("OK", role: .cancel) {}
        } else {
            let safe = plan.clean.count + plan.prune.count
            if safe > 0 {
                let title: String =
                    if !plan.losingWork.isEmpty {
                        "Remove \(safe) Without Work"
                    } else if plan.clean.isEmpty {
                        "Prune"
                    } else {
                        "Remove"
                    }
                Button(title, role: .destructive) { run(plan, losingWork: false) }
            }
            if !plan.losingWork.isEmpty {
                Button(safe > 0 ? "Remove All \(plan.acted.count)…" : "Continue…", role: .destructive) {
                    isConfirmingLoss = true
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func lossTitle(for plan: WorktreeBulkPlan) -> String {
        let count = plan.losingWork.count
        if count == 1 { return "Remove \(plan.losingWork[0].worktree.displayName) anyway?" }
        return "Remove \(count) worktrees with unsaved work anyway?"
    }

    private func lossMessage(for plan: WorktreeBulkPlan) -> String {
        if plan.losingWork.count == 1 { return "This can't be undone." }
        return plan.losingWork.map { loss in
            "\(loss.worktree.displayName): "
                + lossText(loss.worktree, uncommitted: loss.uncommitted, unpushed: loss.unpushed, detached: loss.detached)
        }
        .joined(separator: "\n") + "\n\nThis can't be undone."
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

    private func sizeSuffix(_ worktree: Worktree) -> String {
        worktree.sizeBytes.map { " (\(Self.bytes($0)))" } ?? ""
    }

    private func sizeText(_ worktree: Worktree) -> (text: String, isPending: Bool) {
        if worktree.isPrunable { return ("—", true) }
        if let bytes = worktree.sizeBytes { return (Self.bytes(bytes), false) }
        return store.unmeasurable.contains(worktree.path) ? ("—", true) : ("Measuring…", true)
    }

    private func activityText(_ worktree: Worktree) -> String {
        guard let last = worktree.lastActivity else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        let text = formatter.localizedString(for: last, relativeTo: Date())
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private func openInTerminal(_ path: String) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    // MARK: - Column sorting

    private static func comparators(for sort: WorktreeSort) -> [KeyPathComparator<Worktree>] {
        let order: SortOrder = sort.ascending ? .forward : .reverse
        switch sort.key {
        case .name: return [KeyPathComparator(\.displayName, order: order)]
        case .repo: return [KeyPathComparator(\.repoName, order: order)]
        case .size: return [KeyPathComparator(\.sizeForSort, order: order)]
        case .activity: return [KeyPathComparator(\.activityForSort, order: order)]
        }
    }

    private static func sort(from comparators: [KeyPathComparator<Worktree>]) -> WorktreeSort? {
        guard let first = comparators.first else { return nil }
        let keyPath: AnyKeyPath = first.keyPath
        let key: WorktreeSort.Key
        if keyPath == \Worktree.displayName {
            key = .name
        } else if keyPath == \Worktree.repoName {
            key = .repo
        } else if keyPath == \Worktree.sizeForSort {
            key = .size
        } else if keyPath == \Worktree.activityForSort {
            key = .activity
        } else {
            return nil
        }
        return WorktreeSort(key: key, ascending: first.order == .forward)
    }
}

/// Sort keys the table's column headers can use; the list itself is ordered by the store,
/// which keeps unknown values last in both directions.
private extension Worktree {
    var sizeForSort: Int64 { sizeBytes ?? -1 }
    var activityForSort: Date { lastActivity ?? .distantPast }
}

private extension RepoScan {
    var repoName: String { (repoPath as NSString).lastPathComponent }
}

/// A one-line bar above the table, like Mail's "Filtered by" strip.
private struct NoticeBar<Trailing: View>: View {
    let text: String
    let isError: Bool
    let trailing: () -> Trailing

    init(text: String, isError: Bool = false, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.text = text
        self.isError = isError
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(text)
                .font(.callout)
                .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(text)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// What the list shows and when a worktree counts as flagged.
private struct FilterPopover: View {
    @EnvironmentObject private var store: WorktreeStore

    private static let agePresets = [7, 14, 30, 60, 90]
    private static let sizePresetsGB: [Int64] = [1, 2, 5, 10, 20]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Show") {
                    choice("Flagged", $store.filter.flagged)
                    choice("In Use", $store.filter.inUse)
                    choice("Unsaved Work", $store.filter.withWork)
                    choice("Agent-made", $store.filter.agentMade)
                    choice("Locked", $store.filter.locked)
                    choice("Missing", $store.filter.missing)
                    Picker("Size", selection: $store.filter.minSizeBytes) {
                        ForEach(WorktreeFilter.sizeSteps, id: \.self) { bytes in
                            Text(bytes == 0 ? "Any" : "At least \(WorktreesView.bytes(bytes))").tag(bytes)
                        }
                    }
                    Picker("Idle", selection: $store.filter.minIdleDays) {
                        ForEach(WorktreeFilter.idleSteps, id: \.self) { days in
                            Text(days == 0 ? "Any" : "At least \(Self.idle(days))").tag(days)
                        }
                    }
                }
                Section("Flag When") {
                    Picker("Idle for", selection: ageBinding) {
                        ForEach(options(Self.agePresets, current: store.thresholds.maxAgeDays), id: \.self) { days in
                            Text("\(days) days").tag(days)
                        }
                    }
                    Picker("Larger than", selection: sizeBinding) {
                        ForEach(options(Self.sizePresetsGB, current: store.thresholds.maxSizeBytes / 1_000_000_000), id: \.self) { gb in
                            Text("\(gb) GB").tag(gb)
                        }
                    }
                }
            }
            .formStyle(.columns)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            HStack {
                Spacer()
                Button("Reset") {
                    var reset = WorktreeFilter()
                    reset.query = store.filter.query
                    reset.sort = store.filter.sort
                    store.filter = reset
                    store.thresholds = WorktreeThresholds()
                }
                .disabled(!store.filter.isNarrowed && store.thresholds == WorktreeThresholds())
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 340)
    }

    private func choice(_ label: String, _ binding: Binding<WorktreeFilterChoice>) -> some View {
        Picker(label, selection: binding) {
            Text("Any").tag(WorktreeFilterChoice.any)
            Text("Only").tag(WorktreeFilterChoice.only)
            Text("Hidden").tag(WorktreeFilterChoice.exclude)
        }
    }

    private var ageBinding: Binding<Int> {
        Binding(
            get: { store.thresholds.maxAgeDays },
            set: { store.thresholds.maxAgeDays = $0 }
        )
    }

    private var sizeBinding: Binding<Int64> {
        Binding(
            get: { store.thresholds.maxSizeBytes / 1_000_000_000 },
            set: { store.thresholds.maxSizeBytes = $0 * 1_000_000_000 }
        )
    }

    /// The presets plus the current value, so a custom threshold still shows as selected.
    private func options<T: Hashable & Comparable>(_ presets: [T], current: T) -> [T] {
        Array(Set(presets + [current])).sorted()
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
}

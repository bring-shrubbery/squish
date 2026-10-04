import AppKit
import SquishCore
import SwiftUI

struct WorktreesView: View {
    @EnvironmentObject private var store: WorktreeStore
    @State private var flaggedOnly = false
    @State private var confirmation: Confirmation?
    @State private var skippedAfterBulk: [Worktree] = []

    private enum Confirmation: Identifiable {
        case remove(Worktree)
        case losingWork(Worktree, uncommitted: Int, unpushed: Int, detached: Bool)
        case removeAnyway(Worktree)
        case bulk(remove: [Worktree], skipped: [Worktree])

        var id: String {
            switch self {
            case .remove(let w): "remove-\(w.path)"
            case .losingWork(let w, _, _, _): "losing-\(w.path)"
            case .removeAnyway(let w): "anyway-\(w.path)"
            case .bulk: "bulk"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    PageHeader(
                        eyebrow: "Disk hygiene",
                        title: "Worktrees",
                        subtitle: "Linked git worktrees of the repos in your folder, largest first."
                    )
                    Spacer()
                    Button {
                        store.refresh()
                    } label: {
                        Label(store.isRefreshing ? "Scanning…" : "Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isRefreshing)
                }

                summary

                if store.gitUnavailable {
                    notice(
                        "git is not available",
                        "Squish uses git to find and remove worktrees. Install the command line tools with xcode-select --install, then refresh."
                    )
                } else if store.scans.allSatisfy({ $0.worktrees.isEmpty && $0.error == nil }) && !store.isRefreshing {
                    notice("No linked worktrees", "None of the repos in your folder has a linked worktree.")
                } else {
                    ForEach(store.scans) { scan in
                        repoCard(scan)
                    }
                }

                if !skippedAfterBulk.isEmpty {
                    notice(
                        "Skipped \(skippedAfterBulk.count) with work in them",
                        skippedAfterBulk.map(\.displayName).joined(separator: ", ") + ". Remove these one at a time."
                    )
                }
            }
            .padding(28)
        }
        .onAppear { store.refresh() }
        .alert(
            Text(confirmation.map(title(for:)) ?? ""),
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            presenting: confirmation
        ) { confirmation in
            buttons(for: confirmation)
        } message: { confirmation in
            Text(message(for: confirmation))
        }
    }

    // MARK: - Header

    private var summary: some View {
        HStack(alignment: .center, spacing: 18) {
            stat("On disk", Self.bytes(store.totalBytes))
            stat("Flagged", "\(store.flaggedCount) · \(Self.bytes(store.flaggedBytes))")
            Divider().frame(height: 34)
            Stepper(value: ageBinding, in: 1...365) {
                Text("Older than \(store.thresholds.maxAgeDays) days")
                    .font(.system(size: 12, weight: .medium))
            }
            Stepper(value: sizeBinding, in: 1...200) {
                Text("Larger than \(store.thresholds.maxSizeBytes / 1_000_000_000) GB")
                    .font(.system(size: 12, weight: .medium))
            }
            Spacer()
            Toggle("Flagged only", isOn: $flaggedOnly)
                .toggleStyle(.switch)
                .tint(AppColors.mint)
                .font(.system(size: 12, weight: .medium))
            Button("Remove flagged") {
                let preview = store.bulkPreview()
                confirmation = .bulk(remove: preview.remove, skipped: preview.skipped)
            }
            .disabled(store.flaggedCount == 0 || store.isRemoving)
        }
        .padding(18)
        .appCard()
        .overlay(alignment: .bottomTrailing) {
            if let reclaimed = store.lastReclaimed {
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

    // MARK: - Rows

    private func repoCard(_ scan: RepoScan) -> some View {
        let rows = sortedRows(scan)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(URL(fileURLWithPath: scan.repoPath).lastPathComponent)
                    .font(.system(size: 14, weight: .bold))
                Text(scan.repoPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.bottom, 10)

            if let error = scan.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.coral)
            } else if rows.isEmpty {
                Text(flaggedOnly ? "Nothing flagged." : "No linked worktrees.")
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

    private func sortedRows(_ scan: RepoScan) -> [Worktree] {
        let sized = store.worktrees.filter { $0.repoPath == scan.repoPath }
        let visible = flaggedOnly ? sized.filter { !store.flags(for: $0).isEmpty } : sized
        return visible.sorted { ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1) }
    }

    private func row(_ worktree: Worktree) -> some View {
        let flags = store.flags(for: worktree)
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(worktree.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    if let agent = worktree.agent {
                        chip(agent.rawValue, AppColors.violet)
                    }
                    if worktree.uncommittedCount > 0 { chip("Uncommitted changes", AppColors.amber) }
                    if worktree.unpushedCount > 0 { chip("Unpushed commits", AppColors.amber) }
                    if WorktreePolicy.hasActiveSession(worktree, activeSessionPaths: store.activeSessionPaths) {
                        chip("Session active", AppColors.mint)
                    }
                    if worktree.isLocked { chip("Locked", .secondary) }
                    if worktree.isPrunable { chip("Missing", AppColors.coral) }
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
                .fill(flags.isEmpty ? .clear : AppColors.amber.opacity(0.07))
        )
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
            Button("Remove") { confirmation = .remove(worktree) }
                .disabled(store.isRemoving)
        case let .confirmLosingWork(uncommitted, unpushed, detached):
            Button("Remove") {
                confirmation = .losingWork(worktree, uncommitted: uncommitted, unpushed: unpushed, detached: detached)
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
        case .removeAnyway(let worktree):
            "Remove \(worktree.displayName) anyway?"
        case let .bulk(remove, _):
            "Remove \(remove.count) flagged worktrees (\(Self.bytes(remove.compactMap(\.sizeBytes).reduce(0, +))))?"
        }
    }

    private func message(for confirmation: Confirmation) -> String {
        switch confirmation {
        case .remove(let worktree):
            branchKeptText(worktree)
        case let .losingWork(worktree, uncommitted, unpushed, detached):
            lossText(worktree, uncommitted: uncommitted, unpushed: unpushed, detached: detached)
        case .removeAnyway:
            "This cannot be undone."
        case let .bulk(remove, skipped):
            remove.map(\.displayName).joined(separator: ", ") + ". Their branches are kept."
                + (skipped.isEmpty ? "" : " \(skipped.count) with work in them will be skipped.")
        }
    }

    @ViewBuilder
    private func buttons(for confirmation: Confirmation) -> some View {
        switch confirmation {
        case .remove(let worktree):
            Button("Remove", role: .destructive) { Task { await store.remove(worktree, force: false) } }
        case .losingWork(let worktree, _, _, _):
            Button("Continue…", role: .destructive) {
                // A second, separate confirmation, presented after this alert has closed.
                DispatchQueue.main.async { self.confirmation = .removeAnyway(worktree) }
            }
        case .removeAnyway(let worktree):
            Button("Remove anyway", role: .destructive) { Task { await store.remove(worktree, force: true) } }
        case .bulk:
            Button("Remove", role: .destructive) { Task { skippedAfterBulk = await store.removeFlagged() } }
        }
        Button("Cancel", role: .cancel) {}
    }

    private func branchKeptText(_ worktree: Worktree) -> String {
        if let branch = worktree.branch { return "The branch \(branch) is kept." }
        return "It is on a detached HEAD; nothing is lost because it has no unique commits."
    }

    private func lossText(_ worktree: Worktree, uncommitted: Int, unpushed: Int, detached: Bool) -> String {
        var lines: [String] = []
        if uncommitted > 0 {
            lines.append("\(uncommitted) uncommitted \(uncommitted == 1 ? "file" : "files") will be deleted.")
        }
        if unpushed > 0 {
            let commits = "\(unpushed) \(unpushed == 1 ? "commit is" : "commits are") on no remote or other branch"
            if detached {
                lines.append("\(commits) and will only be reachable through git's reflog.")
            } else {
                lines.append("\(commits); \(unpushed == 1 ? "it stays" : "they stay") on branch \(worktree.branch ?? "").")
            }
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Helpers

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

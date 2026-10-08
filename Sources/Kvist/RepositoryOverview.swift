import AppKit
import SwiftUI

// MARK: - Pure decisions

/// One repository in the overview: every known checkout of one origin, or a
/// single checkout whose origin is unknown.
struct RepositoryOverviewSection: Identifiable, Equatable {
    let id: String
    let title: String
    let origin: String?
    let checkouts: [Checkout]
}

enum PullDecision: Equatable {
    case pull
    case skip(String)
}

/// What a bulk action did to one checkout.
enum CheckoutActionResult: Equatable {
    case fetched
    case pulled
    case skipped(String)
    case failed(String)

    var text: String {
        switch self {
        case .fetched: "Fetched"
        case .pulled: "Pulled"
        case .skipped(let reason): "Skipped: \(reason)"
        case .failed(let message): message
        }
    }
}

enum RepositoryOverviewLogic {
    /// Groups checkouts by origin and sorts them. Sections sort by title.
    /// Rows put this Mac first, then hosts by name, then paths. A non-empty
    /// `query` keeps checkouts whose name, host, path, origin, or branch
    /// contains it, ignoring case.
    static func sections(
        checkouts: [Checkout],
        statuses: [Checkout.ID: CheckoutStatus],
        query: String = ""
    ) -> [RepositoryOverviewSection] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = checkouts.filter { checkout in
            guard !query.isEmpty else { return true }
            let fields = [
                checkout.name, checkout.machineName, checkout.host ?? "",
                checkout.path, checkout.origin ?? "", statuses[checkout.id]?.branch ?? ""
            ]
            return fields.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        let groups = Dictionary(grouping: matching) { $0.origin ?? "checkout:\($0.id)" }
        return groups.map { key, members in
            let origin = members.first?.origin
            let title = origin.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? members[0].name
            return RepositoryOverviewSection(
                id: key,
                title: title,
                origin: origin,
                checkouts: members.sorted(by: rowOrder)
            )
        }
        .sorted {
            let order = $0.title.localizedCaseInsensitiveCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private static func rowOrder(_ a: Checkout, _ b: Checkout) -> Bool {
        switch (a.host, b.host) {
        case (nil, .some): return true
        case (.some, nil): return false
        case let (x?, y?) where x != y: return x.localizedCaseInsensitiveCompare(y) == .orderedAscending
        default: return a.path.localizedCaseInsensitiveCompare(b.path) == .orderedAscending
        }
    }

    /// Whether Pull All may fast-forward a checkout, from a fresh status.
    /// Anything that could need a merge, a stash, or a decision is skipped.
    static func pullDecision(status: CheckoutStatus?, failure: String?) -> PullDecision {
        if let failure { return .skip("unreachable (\(failure))") }
        guard let status else { return .skip("status unknown") }
        if !status.isClean { return .skip("has uncommitted changes") }
        if !status.hasUpstream { return .skip("no upstream branch") }
        if status.ahead > 0, status.behind > 0 { return .skip("diverged from upstream") }
        if status.behind == 0 { return .skip("already up to date") }
        return .pull
    }

    /// "Pulled 4, skipped 3, failed 1". Leaves out zero counts.
    static func summary(verb: String, results: [CheckoutActionResult]) -> String {
        var done = 0, skipped = 0, failed = 0
        for result in results {
            switch result {
            case .fetched, .pulled: done += 1
            case .skipped: skipped += 1
            case .failed: failed += 1
            }
        }
        let parts = [(verb, done), ("skipped", skipped), ("failed", failed)]
            .filter { $0.1 > 0 }
            .map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "Nothing to do" : parts.joined(separator: ", ")
    }
}

extension GitClient {
    /// Pulls only when the branch can fast-forward, so it never creates a
    /// merge commit or stops on conflicts.
    func pullFastForwardOnly() throws -> String {
        try run(["pull", "--ff-only", "--progress"], timeout: 120)
    }
}

// MARK: - Actions

@MainActor
final class RepositoryOverviewModel: ObservableObject {
    @Published private(set) var results: [Checkout.ID: CheckoutActionResult] = [:]
    @Published private(set) var summary: String?
    @Published private(set) var isRunning = false

    func fetch(
        _ checkouts: [Checkout], registry: CheckoutRegistry, tabs: WorkspaceTabsModel
    ) async {
        await perform(checkouts, verb: "Fetched", registry: registry, tabs: tabs) { targets in
            await self.runPerHost(targets, work: Self.fetchWork) { self.results[$0] = $1 }
        }
    }

    func pull(
        _ checkouts: [Checkout], registry: CheckoutRegistry, tabs: WorkspaceTabsModel
    ) async {
        await perform(checkouts, verb: "Pulled", registry: registry, tabs: tabs) { targets in
            // Fetch first so "behind" reflects the remote, then decide from
            // fresh statuses.
            var fetchFailed: Set<Checkout.ID> = []
            await self.runPerHost(targets, work: Self.fetchWork) { id, result in
                if case .failed = result {
                    self.results[id] = result
                    fetchFailed.insert(id)
                }
            }
            let fetched = targets.filter { !fetchFailed.contains($0.id) }
            await registry.refresh(fetched, maximumAge: 0)
            var toPull: [Checkout] = []
            for checkout in fetched {
                switch RepositoryOverviewLogic.pullDecision(
                    status: registry.statuses[checkout.id],
                    failure: registry.failures[checkout.id]
                ) {
                case .pull: toPull.append(checkout)
                case .skip(let reason): self.results[checkout.id] = .skipped(reason)
                }
            }
            await self.runPerHost(toPull, work: Self.pullWork) { self.results[$0] = $1 }
        }
    }

    private func perform(
        _ checkouts: [Checkout],
        verb: String,
        registry: CheckoutRegistry,
        tabs: WorkspaceTabsModel,
        body: ([Checkout]) async -> Void
    ) async {
        guard !isRunning, !checkouts.isEmpty else { return }
        isRunning = true
        summary = nil
        for checkout in checkouts { results[checkout.id] = nil }
        defer { isRunning = false }

        // Statuses tell which checkouts are reachable. A checkout that
        // failed its last read is skipped instead of waiting on a timeout.
        await registry.refresh(checkouts, maximumAge: 30)
        var targets: [Checkout] = []
        for checkout in checkouts {
            if let failure = registry.failures[checkout.id] {
                results[checkout.id] = .skipped("unreachable (\(failure))")
            } else {
                targets.append(checkout)
            }
        }
        await body(targets)

        summary = RepositoryOverviewLogic.summary(
            verb: verb, results: checkouts.compactMap { results[$0.id] }
        )
        await registry.refresh(targets, maximumAge: 0)
        for tab in tabs.tabs where targets.contains(where: { tab.shows($0.worktree) }) {
            await tab.loadedModel?.refresh()
        }
    }

    /// Runs `work` on every checkout, one after another on each host and all
    /// hosts at once, so one SSH host never gets many parallel Git commands.
    private func runPerHost(
        _ checkouts: [Checkout],
        work: @escaping @Sendable (Checkout) -> CheckoutActionResult,
        record: @escaping (Checkout.ID, CheckoutActionResult) -> Void
    ) async {
        let byHost = Dictionary(grouping: checkouts, by: \.host)
        await withTaskGroup(of: Void.self) { group in
            for items in byHost.values {
                group.addTask {
                    for checkout in items {
                        let result = await Task.detached(priority: .utility) { work(checkout) }.value
                        await MainActor.run { record(checkout.id, result) }
                    }
                }
            }
        }
    }

    private nonisolated static func client(for checkout: Checkout) throws -> GitClient {
        let url = URL(fileURLWithPath: checkout.path, isDirectory: true)
        // `GitClient.run` ignores the URL for SSH and runs in the remote path.
        let remote = try checkout.host.map { try SSHRepository(host: $0, path: checkout.path) }
        return GitClient(repositoryURL: url, sshRepository: remote)
    }

    private nonisolated static func fetchWork(_ checkout: Checkout) -> CheckoutActionResult {
        do {
            _ = try client(for: checkout).fetch()
            return .fetched
        } catch {
            return .failed(message(for: error))
        }
    }

    private nonisolated static func pullWork(_ checkout: Checkout) -> CheckoutActionResult {
        do {
            _ = try client(for: checkout).pullFastForwardOnly()
            return .pulled
        } catch {
            return .failed(message(for: error))
        }
    }

    private nonisolated static func message(for error: Error) -> String {
        let text = (error as? GitCommandError)?.output ?? error.localizedDescription
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(whereSeparator: \.isNewline).last.map(String.init) ?? "Failed"
    }
}

// MARK: - View

struct RepositoryOverviewView: View {
    @EnvironmentObject private var registry: CheckoutRegistry
    @EnvironmentObject private var tabsModel: WorkspaceTabsModel
    @StateObject private var model = RepositoryOverviewModel()
    @State private var query = ""

    private var sections: [RepositoryOverviewSection] {
        RepositoryOverviewLogic.sections(
            checkouts: registry.checkouts, statuses: registry.statuses, query: query
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if registry.checkouts.isEmpty {
                emptyState(
                    "No repositories yet",
                    "Open a repository in Kvist, or add SSH hosts in Settings, and its checkouts appear here."
                )
            } else if sections.isEmpty {
                emptyState("No matches", "No checkout matches \"\(query)\".")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(16)
                }
            }
            if let summary = model.summary {
                Text(summary)
                    .font(AppType.caption)
                    .foregroundStyle(AppTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(AppTheme.raisedFill)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.canvas)
        .foregroundStyle(AppTheme.primary)
        .searchable(text: $query, prompt: "Filter by name, host, or branch")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.fetch(registry.checkouts, registry: registry, tabs: tabsModel) }
                } label: {
                    Label("Fetch All", systemImage: "arrow.down.circle")
                }
                .help("Fetch every checkout")
                .disabled(model.isRunning)
                Button {
                    Task { await model.pull(registry.checkouts, registry: registry, tabs: tabsModel) }
                } label: {
                    Label("Pull All", systemImage: "arrow.down.to.line")
                }
                .help("Fast-forward every checkout that is behind and clean")
                .disabled(model.isRunning)
                Button {
                    Task { await registry.refresh(registry.checkouts, maximumAge: 0) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Read every checkout's status again")
            }
        }
        .task {
            while !Task.isCancelled {
                await registry.refresh(registry.checkouts, maximumAge: 60)
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    private func emptyState(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(AppType.sectionTitle)
            Text(detail)
                .font(AppType.rowDetail)
                .foregroundStyle(AppTheme.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionView(_ section: RepositoryOverviewSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(section.title).font(AppType.sectionTitle)
                if let origin = section.origin {
                    Text(origin)
                        .font(AppType.caption)
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 8)
            ForEach(section.checkouts) { checkout in
                RepositoryOverviewRow(checkout: checkout, model: model)
            }
        }
    }
}

private struct RepositoryOverviewRow: View {
    let checkout: Checkout
    @ObservedObject var model: RepositoryOverviewModel
    @EnvironmentObject private var registry: CheckoutRegistry
    @EnvironmentObject private var tabsModel: WorkspaceTabsModel
    @State private var isHovered = false

    private var status: CheckoutStatus? { registry.statuses[checkout.id] }
    private var failure: String? { registry.failures[checkout.id] }

    var body: some View {
        HStack(spacing: 10) {
            machine
            Text(checkout.path)
                .font(AppType.rowDetail)
                .foregroundStyle(AppTheme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            detail
            ZStack {
                if registry.refreshingIDs.contains(checkout.id) {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 18)
            Button("Open") { open() }
                .buttonStyle(.borderless)
                .font(AppType.captionEmphasis)
                .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isHovered ? AppTheme.hover : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .opacity(failure == nil ? 1 : 0.55)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { open() }
        .contextMenu { menu }
    }

    private var machine: some View {
        HStack(spacing: 6) {
            if checkout.host != nil {
                SSHLogo().scaledToFit().frame(width: 14, height: 14)
            } else {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 12))
                    .frame(width: 14, height: 14)
                    .foregroundStyle(AppTheme.secondary)
            }
            Text(checkout.machineName)
                .font(AppType.rowEmphasis)
                .lineLimit(1)
        }
        .frame(width: 130, alignment: .leading)
    }

    @ViewBuilder
    private var detail: some View {
        if let result = model.results[checkout.id] {
            Text(result.text)
                .font(AppType.caption)
                .foregroundStyle(color(for: result))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260, alignment: .trailing)
                .help(result.text)
        } else if let failure {
            Text(failure)
                .font(AppType.caption)
                .foregroundStyle(AppTheme.deleted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260, alignment: .trailing)
                .help(failure)
        } else if let status {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    CodiconGlyph(icon: .gitBranch, size: 12, color: AppTheme.muted)
                    Text(status.branch)
                        .font(AppType.rowDetail)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(width: 140, alignment: .leading)
                Text(status.isClean ? "clean" : "\(status.changeCount) changed")
                    .font(AppType.caption)
                    .foregroundStyle(status.isClean ? AppTheme.muted : AppTheme.modified)
                    .frame(width: 70, alignment: .trailing)
                Text(syncText(status))
                    .font(AppType.caption)
                    .foregroundStyle(AppTheme.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
        }
    }

    private func syncText(_ status: CheckoutStatus) -> String {
        guard status.hasUpstream else { return "no upstream" }
        var parts: [String] = []
        if status.behind > 0 { parts.append("\(status.behind)↓") }
        if status.ahead > 0 { parts.append("\(status.ahead)↑") }
        return parts.isEmpty ? "synced" : parts.joined(separator: " ")
    }

    private func color(for result: CheckoutActionResult) -> Color {
        switch result {
        case .fetched, .pulled: AppTheme.added
        case .skipped: AppTheme.muted
        case .failed: AppTheme.deleted
        }
    }

    private func open() {
        tabsModel.open(checkout)
        NSApp.activate(ignoringOtherApps: true)
        WindowConfigurator.mainWindow?.makeKeyAndOrderFront(nil)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open") { open() }
        Divider()
        Button("Fetch") {
            Task { await model.fetch([checkout], registry: registry, tabs: tabsModel) }
        }
        .disabled(model.isRunning)
        Button("Pull") {
            Task { await model.pull([checkout], registry: registry, tabs: tabsModel) }
        }
        .disabled(model.isRunning)
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(checkout.location, forType: .string)
        }
        if checkout.host == nil {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: checkout.path)])
            }
        }
        Divider()
        Button("Remove from Kvist") { registry.remove(checkout.id) }
    }
}

import AppKit
import SwiftUI

/// One repository on the welcome screen, with its checkouts on every
/// machine. Clones that share an origin are one repository.
struct PickerRepository: Identifiable, Equatable {
    let id: String
    let name: String
    /// This Mac first, then hosts by name, then paths.
    let checkouts: [Checkout]
    /// The checkout a click on the row opens: the most recently used one,
    /// else the one on this Mac, else the first.
    let preferred: Checkout
    /// Position in the recent list, or nil when never opened recently.
    let recentRank: Int?

    var isLocal: Bool { checkouts.contains { $0.host == nil } }

    /// The machine name, with the folder name when the folder differs from
    /// the repository's name or one machine has several checkouts.
    func label(for checkout: Checkout) -> String {
        let sameMachine = checkouts.filter { $0.host == checkout.host }
        guard checkout.name != name || sameMachine.count > 1 else { return checkout.machineName }
        return "\(checkout.machineName) · \(checkout.name)"
    }

    /// Merges recent, registered, and discovered checkouts into repositories.
    /// Recently used repositories come first, the rest by name. A non-empty
    /// `query` keeps repositories whose name, origin, machine, or path
    /// contains it.
    static func list(recent: [Checkout], known: [Checkout], query: String = "") -> [PickerRepository] {
        var byID: [Checkout.ID: Checkout] = [:]
        var order: [Checkout.ID] = []
        for checkout in recent + known {
            if var existing = byID[checkout.id] {
                existing.origin = existing.origin ?? checkout.origin
                byID[checkout.id] = existing
            } else {
                byID[checkout.id] = checkout
                order.append(checkout.id)
            }
        }
        let recentRanks = Dictionary(
            recent.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var groups: [String: [Checkout]] = [:]
        var groupOrder: [String] = []
        for id in order {
            guard let checkout = byID[id] else { continue }
            let key = checkout.origin ?? "path:\(checkout.id)"
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(checkout)
        }

        let repositories = groupOrder.compactMap { key -> PickerRepository? in
            guard let members = groups[key] else { return nil }
            let checkouts = members.sorted {
                ($0.host == nil ? 0 : 1, $0.host ?? "", $0.path)
                    < ($1.host == nil ? 0 : 1, $1.host ?? "", $1.path)
            }
            let rank = checkouts.compactMap { recentRanks[$0.id] }.min()
            let preferred = checkouts.first { rank != nil && recentRanks[$0.id] == rank }
                ?? checkouts[0]
            return PickerRepository(
                id: key,
                name: preferred.name,
                checkouts: checkouts,
                preferred: preferred,
                recentRank: rank
            )
        }
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        return repositories
            .filter { repository in
                query.isEmpty
                    || repository.name.lowercased().contains(query)
                    || repository.id.lowercased().contains(query)
                    || repository.checkouts.contains {
                        $0.location.lowercased().contains(query)
                            || $0.machineName.lowercased().contains(query)
                    }
            }
            .sorted { first, second in
                switch (first.recentRank, second.recentRank) {
                case let (a?, b?): return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil):
                    return first.name.localizedStandardCompare(second.name) == .orderedAscending
                }
            }
    }
}

/// Every repository Kvist knows on this Mac and the SSH hosts, for the
/// welcome screen. Scans that are more than six hours old run again while
/// the list is on screen.
struct RepositoryPickerList: View {
    @EnvironmentObject private var model: RepositoryModel
    @EnvironmentObject private var tabsModel: WorkspaceTabsModel
    @EnvironmentObject private var registry: CheckoutRegistry
    @EnvironmentObject private var hosts: SSHHostsModel
    @State private var query = ""

    private static let rescanAge: TimeInterval = 6 * 60 * 60
    private static let filterThreshold = 8

    private var recent: [Checkout] {
        tabsModel.recentRepositoryURLs.map { url in
            if let remote = SSHRepository.mirrored(at: url) {
                return Checkout(host: remote.host, path: remote.path)
            }
            return Checkout(host: nil, path: url.standardizedFileURL.path)
        }
    }

    /// Local checkouts whose folder is gone are left out, as recents are.
    private var known: [Checkout] {
        (registry.checkouts + hosts.discovered).filter {
            $0.host != nil || FileManager.default.fileExists(atPath: $0.path)
        }
    }

    var body: some View {
        let recent = recent
        let known = known
        let all = PickerRepository.list(recent: recent, known: known)
        let repositories = query.isEmpty
            ? all
            : PickerRepository.list(recent: recent, known: known, query: query)
        VStack(alignment: .leading, spacing: 4) {
            header

            if all.count > Self.filterThreshold {
                TextField("Filter", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(AppType.rowDetail)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            }

            if all.isEmpty, hosts.isScanning {
                Text("Looking for repositories…")
                    .font(AppType.rowDetail)
                    .foregroundStyle(AppTheme.muted)
                    .padding(.leading, 9)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(repositories) { repository in
                        PickerRepositoryRow(repository: repository, open: open)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 340)

            if !hosts.unreachableHosts.isEmpty {
                Text("Could not reach \(hosts.unreachableHosts.map(\.host).joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(2)
                    .padding(.leading, 9)
                    .padding(.top, 4)
                    .help(hosts.unreachableHosts.map { "\($0.host): \($0.error)" }.joined(separator: "\n"))
            }
        }
        .frame(width: 360)
        .task {
            await hosts.discover(maximumAge: Self.rescanAge)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("REPOSITORIES")
                .font(AppType.panelTitle)
                .tracking(0.8)
                .foregroundStyle(AppTheme.muted)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            if hosts.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
                    .help("Looking for repositories on this Mac and your SSH hosts")
            } else {
                Button {
                    Task { await hosts.discover(maximumAge: 0) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.muted)
                .help("Look for repositories on this Mac and your SSH hosts again")
                .accessibilityLabel("Scan Again")
            }
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 4)
    }

    /// Selects a tab that already shows the checkout. Otherwise the welcome
    /// tab opens it, so no empty tab is left behind.
    private func open(_ checkout: Checkout) {
        if tabsModel.isOpen(checkout) {
            tabsModel.open(checkout)
            return
        }
        Task {
            if let host = checkout.host {
                await model.openSSHRepository(host: host, path: checkout.path)
            } else {
                await model.openRepository(URL(fileURLWithPath: checkout.path, isDirectory: true))
            }
        }
    }
}

struct PickerRepositoryRow: View {
    @EnvironmentObject private var model: RepositoryModel
    @EnvironmentObject private var tabsModel: WorkspaceTabsModel
    let repository: PickerRepository
    let open: (Checkout) -> Void
    @State private var hovering = false

    private var isDisabled: Bool {
        model.isBusy || model.isGeneratingCommitMessage || model.hasPendingChangeOperations
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: repository.isLocal ? "folder" : "network")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(repository.name)
                    .font(AppType.rowDetail)
                    .foregroundStyle(AppTheme.primary)
                    .lineLimit(1)

                // A plain HStack clips long lists of machines instead of
                // wrapping, so the row keeps one height.
                HStack(spacing: 4) {
                    ForEach(repository.checkouts) { checkout in
                        machineButton(checkout)
                    }
                }
                .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(hovering ? AppTheme.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovering = $0 }
        .onTapGesture { if !isDisabled { open(repository.preferred) } }
        .help(repository.preferred.location)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(repository.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if !isDisabled { open(repository.preferred) } }
        .contextMenu { menu }
    }

    private func machineButton(_ checkout: Checkout) -> some View {
        Button {
            open(checkout)
        } label: {
            Text(repository.label(for: checkout))
                .font(.system(size: 11))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(AppTheme.raisedFill, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.secondary)
        .disabled(isDisabled)
        .help("Open \(checkout.location)")
    }

    @ViewBuilder
    private var menu: some View {
        ForEach(repository.checkouts) { checkout in
            Button("Open on \(repository.label(for: checkout))") { open(checkout) }
        }
        if let local = repository.checkouts.first(where: { $0.host == nil }) {
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([
                    URL(fileURLWithPath: local.path, isDirectory: true)
                ])
            }
        }
        if repository.recentRank != nil {
            Divider()
            Button("Remove from Recents") {
                for path in tabsModel.recentRepositoryPaths {
                    let url = URL(fileURLWithPath: path, isDirectory: true)
                    let remote = SSHRepository.mirrored(at: url)
                    let id = Checkout(host: remote?.host, path: remote?.path ?? url.standardizedFileURL.path).id
                    if repository.checkouts.contains(where: { $0.id == id }) {
                        tabsModel.removeRecentRepository(path: path)
                    }
                }
            }
        }
    }
}

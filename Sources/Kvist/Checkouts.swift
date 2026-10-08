import Combine
import Foundation

/// A folder with a Git repository, on this Mac when `host` is nil or on an
/// SSH host. Clones of one remote repository share an `origin`, which is how
/// Kvist shows `~/code/x` and `devbox:/srv/x` as one repository.
struct Checkout: Codable, Hashable, Identifiable, Sendable {
    var host: String?
    var path: String
    /// The `origin` remote's URL after `normalizedOrigin`, or nil before
    /// Kvist reads it or when the repository has no usable origin.
    var origin: String?

    init(host: String?, path: String, origin: String? = nil) {
        self.host = host
        self.path = path
        self.origin = origin
    }

    var id: String { "\(host ?? ""):\(path)" }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    /// `host:/path` for SSH, which `scp` and `rsync` also accept.
    var location: String { host.map { "\($0):\(path)" } ?? path }
    /// The host without its user name, or "This Mac".
    var machineName: String {
        guard let host else { return "This Mac" }
        return host.split(separator: "@").last.map(String.init) ?? host
    }

    var worktree: GitWorktree { GitWorktree(path: path, branch: nil, sshHost: host) }

    /// Reduces a remote URL to `host/owner/name`, so `git@github.com:me/x.git`,
    /// `ssh://git@github.com:22/me/x` and `https://github.com/me/x/` match.
    /// Returns nil for a local path, which names a different folder on each
    /// machine.
    static func normalizedOrigin(_ url: String) -> String? {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let host: String
        var path: String
        if value.contains("://") {
            guard !value.lowercased().hasPrefix("file:"),
                  let components = URLComponents(string: value),
                  let componentsHost = components.host,
                  !componentsHost.isEmpty else { return nil }
            host = componentsHost
            path = components.path
        } else {
            // scp-like syntax, `user@host:path`. A colon after a slash
            // means a local path such as `./a:b`.
            guard let colon = value.firstIndex(of: ":"),
                  !value[..<colon].contains("/") else { return nil }
            host = String(value[..<colon]).split(separator: "@").last.map(String.init) ?? ""
            path = String(value[value.index(after: colon)...])
        }
        guard !host.isEmpty else { return nil }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/~"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return nil }
        value = "\(host)/\(path)"
        // GitHub and GitLab ignore case in owner and repository names.
        return value.lowercased()
    }
}

/// A checkout's state from `git status --porcelain=v2 --branch`.
struct CheckoutStatus: Equatable, Sendable {
    var branch: String
    var ahead: Int
    var behind: Int
    var hasUpstream: Bool
    /// Files with staged or unstaged changes, counting a file in both once.
    var changeCount: Int
    var origin: String?
    var updatedAt: Date

    var isClean: Bool { changeCount == 0 }
}

/// Every checkout Kvist knows, on this Mac and on SSH hosts, with the last
/// status read for each. Views that show statuses call `refresh(_:)` while
/// they are on screen, so nothing polls when no view needs it.
@MainActor
final class CheckoutRegistry: ObservableObject {
    @Published private(set) var checkouts: [Checkout] = []
    @Published private(set) var statuses: [Checkout.ID: CheckoutStatus] = [:]
    /// The last error per checkout, such as an unreachable host or a folder
    /// that is gone. A successful refresh clears it.
    @Published private(set) var failures: [Checkout.ID: String] = [:]
    @Published private(set) var refreshingIDs: Set<Checkout.ID> = []

    private let defaults: UserDefaults
    private let persistenceEnabled: Bool
    private let checkoutsKey = "knownCheckouts"

    init(defaults: UserDefaults = .standard, persistenceEnabled: Bool = true) {
        self.defaults = defaults
        self.persistenceEnabled = persistenceEnabled
        checkouts = defaults.data(forKey: checkoutsKey).flatMap {
            try? JSONDecoder().decode([Checkout].self, from: $0)
        } ?? []
    }

    func checkout(id: Checkout.ID) -> Checkout? {
        checkouts.first { $0.id == id }
    }

    /// Clones of the same remote repository, or just `checkout` when its
    /// origin is unknown.
    func checkouts(sameRepositoryAs checkout: Checkout) -> [Checkout] {
        guard let origin = checkout.origin ?? self.checkout(id: checkout.id)?.origin else {
            return [self.checkout(id: checkout.id) ?? checkout]
        }
        return checkouts.filter { $0.origin == origin }
    }

    /// Adds the checkout, or records its origin if Kvist already knows it.
    /// A nil origin never clears a known one.
    func register(_ checkout: Checkout) {
        if let index = checkouts.firstIndex(where: { $0.id == checkout.id }) {
            guard let origin = checkout.origin, checkouts[index].origin != origin else { return }
            checkouts[index].origin = origin
        } else {
            checkouts.append(checkout)
        }
        persist()
    }

    func remove(_ id: Checkout.ID) {
        checkouts.removeAll { $0.id == id }
        statuses[id] = nil
        failures[id] = nil
        persist()
    }

    /// Reads the status of each checkout, one SSH round trip per host and
    /// all hosts at once. Checkouts read less than `maximumAge` ago and
    /// checkouts already being read are skipped.
    func refresh(_ requested: [Checkout], maximumAge: TimeInterval = 0) async {
        let now = Date()
        let due = requested.filter { checkout in
            !refreshingIDs.contains(checkout.id)
                && (statuses[checkout.id].map { now.timeIntervalSince($0.updatedAt) >= maximumAge } ?? true)
        }
        guard !due.isEmpty else { return }
        refreshingIDs.formUnion(due.map(\.id))
        defer { refreshingIDs.subtract(due.map(\.id)) }

        let byHost = Dictionary(grouping: due, by: \.host)
        await withTaskGroup(of: (String?, [String: Result<CheckoutStatus, Error>]).self) { group in
            for (host, checkouts) in byHost {
                let paths = checkouts.map(\.path)
                group.addTask {
                    let results = await Task.detached(priority: .utility) {
                        GitClient.checkoutStatuses(host: host, paths: paths)
                    }.value
                    return (host, results)
                }
            }
            for await (host, results) in group {
                for (path, result) in results {
                    let id = Checkout(host: host, path: path).id
                    switch result {
                    case .success(let status):
                        statuses[id] = status
                        failures[id] = nil
                        register(Checkout(host: host, path: path, origin: status.origin))
                    case .failure(let error):
                        failures[id] = (error as? GitCommandError)?.output
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            ?? error.localizedDescription
                    }
                }
            }
        }
    }

    private func persist() {
        guard persistenceEnabled,
              let data = try? JSONEncoder().encode(checkouts) else { return }
        defaults.set(data, forKey: checkoutsKey)
    }
}

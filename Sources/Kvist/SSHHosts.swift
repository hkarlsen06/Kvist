import Combine
import Foundation
import SwiftUI

/// Reads host names out of an OpenSSH client configuration.
enum SSHConfigHosts {
    /// The names on `Host` lines, without wildcard or negated patterns
    /// (`*`, `?`, `!`), in file order and without repeats. `Match` blocks and
    /// `Include` files are not read.
    /// One name per `Host` line, since the names on a line are aliases of
    /// one machine. A name is preferred over an IP address.
    static func machines(in config: String) -> [String] {
        var result: [String] = []
        for rawLine in config.split(whereSeparator: \.isNewline) {
            let names = hosts(in: String(rawLine))
            let isAddress: (String) -> Bool = { name in
                name.contains(":") || name.allSatisfy { $0.isNumber || $0 == "." }
            }
            if let name = names.first(where: { !isAddress($0) }) ?? names.first,
               !result.contains(name) {
                result.append(name)
            }
        }
        return result
    }

    static func hosts(in config: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawLine in config.split(whereSeparator: \.isNewline) {
            let line = (rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard line.count > 4, line.lowercased().hasPrefix("host"),
                  let separator = line.dropFirst(4).first,
                  separator == " " || separator == "\t" || separator == "=" else { continue }
            let names = line.dropFirst(5)
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            for name in names.map(String.init) {
                guard !name.contains(where: { "*?!".contains($0) }),
                      seen.insert(name).inserted else { continue }
                result.append(name)
            }
        }
        return result
    }

    static func userConfigHosts() -> [String] {
        hosts(in: userConfig)
    }

    static func userConfigMachines() -> [String] {
        machines(in: userConfig)
    }

    private static var userConfig: String {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

/// A repository a scan found, with what Kvist already knows about it.
struct ScanCandidate: Identifiable, Equatable, Sendable {
    let checkout: Checkout
    /// Already in the checkout registry.
    let isRegistered: Bool
    /// A registered checkout of the same remote repository on another path
    /// or machine.
    let match: Checkout?

    var id: Checkout.ID { checkout.id }
    var isPreselected: Bool { isRegistered || match != nil }
    var matchNote: String? {
        match.map { "Matches \($0.name) on \($0.machineName)" }
    }

    /// Marks each found checkout as registered and finds the registered
    /// checkout that shares its origin. A checkout without an origin never
    /// matches.
    static func annotate(found: [Checkout], registered: [Checkout]) -> [ScanCandidate] {
        let registeredIDs = Set(registered.map(\.id))
        return found.map { checkout in
            let match = checkout.origin.flatMap { origin in
                registered.first { $0.origin == origin && $0.id != checkout.id }
            }
            return ScanCandidate(
                checkout: checkout,
                isRegistered: registeredIDs.contains(checkout.id),
                match: match
            )
        }
    }
}

/// The result of scanning one or more machines, shown for review before
/// anything reaches the registry.
struct ScanReview: Identifiable {
    let id = UUID()
    let candidates: [ScanCandidate]
}

struct HostScanState: Equatable {
    var isScanning = false
    var lastScan: Date?
    /// The last scan that started, finished or not. Not saved, so a host
    /// that failed is tried again after relaunch.
    var lastAttempt: Date?
    var repositoryCount = 0
    /// The scan stopped at its limit, so more repositories may exist.
    var isTruncated = false
    var error: String?
}

@MainActor
final class SSHHostsModel: ObservableObject {
    nonisolated static let scanLimit = 200
    nonisolated static let statusBatchSize = 50

    @Published private(set) var hosts: [String] = []
    /// Keyed by host, with nil for this Mac.
    @Published private(set) var states: [String?: HostScanState] = [:]
    @Published var review: ScanReview?
    /// Every repository the last scan of each machine found, whether or
    /// not it was added to the registry. The welcome screen lists these.
    @Published private(set) var discovered: [Checkout] = []

    private let defaults: UserDefaults
    private let persistenceEnabled: Bool
    private let hostsKey = "sshHosts"
    private let discoveredKey = "discoveredCheckouts"
    /// Keyed by host, with "" for this Mac.
    private let scanDatesKey = "machineScanDates"

    /// Until the user edits the list, the hosts are those named in
    /// `~/.ssh/config`.
    init(defaults: UserDefaults = .standard, persistenceEnabled: Bool = true) {
        self.defaults = defaults
        self.persistenceEnabled = persistenceEnabled
        if let stored = defaults.stringArray(forKey: hostsKey) {
            hosts = stored
        } else if persistenceEnabled {
            hosts = SSHConfigHosts.userConfigMachines().filter {
                (try? SSHRepository.validatedHost($0)) != nil
            }
        }
        discovered = defaults.data(forKey: discoveredKey).flatMap {
            try? JSONDecoder().decode([Checkout].self, from: $0)
        } ?? []
        let dates = defaults.dictionary(forKey: scanDatesKey) as? [String: Date] ?? [:]
        for (key, date) in dates {
            states[key.isEmpty ? nil : key] = HostScanState(lastScan: date)
        }
    }

    /// Hosts whose last scan failed, with the error.
    var unreachableHosts: [(host: String, error: String)] {
        hosts.compactMap { host in states[host]?.error.map { (host, $0) } }
    }

    /// Scans, without a review, each machine not scanned within
    /// `maximumAge`. Results only update `discovered`.
    func discover(maximumAge: TimeInterval) async {
        guard persistenceEnabled else { return }
        let now = Date()
        let due = ([nil] + hosts.map { Optional($0) }).filter { target in
            let last = states[target].flatMap { $0.lastAttempt ?? $0.lastScan }
            return last.map { now.timeIntervalSince($0) >= maximumAge } ?? true
        }
        _ = await runScans(due)
    }

    var isScanning: Bool { states.values.contains { $0.isScanning } }

    /// Adds a host after validating it. Returns the stored spelling.
    @discardableResult
    func add(_ host: String) throws -> String {
        let host = try SSHRepository.validatedHost(host)
        if !hosts.contains(host) {
            hosts.append(host)
            defaults.set(hosts, forKey: hostsKey)
        }
        return host
    }

    func remove(_ host: String) {
        hosts.removeAll { $0 == host }
        states[host] = nil
        discovered.removeAll { $0.host == host }
        defaults.set(hosts, forKey: hostsKey)
        persistDiscoveries()
    }

    /// Scans the machines at once. Finished scans open a review with the
    /// repositories found, unless every scan failed or found nothing.
    func scan(_ targets: [String?], registry: CheckoutRegistry) async {
        let all = await runScans(targets)
        guard !all.isEmpty else { return }
        review = ScanReview(
            candidates: ScanCandidate.annotate(found: all, registered: registry.checkouts)
        )
    }

    /// Scans the machines that are not already being scanned, all at once,
    /// and returns what they found.
    private func runScans(_ targets: [String?]) async -> [Checkout] {
        let targets = targets.filter { !(states[$0]?.isScanning ?? false) }
        guard !targets.isEmpty else { return [] }
        for target in targets {
            states[target] = HostScanState(
                isScanning: true,
                lastScan: states[target]?.lastScan,
                lastAttempt: Date(),
                repositoryCount: states[target]?.repositoryCount ?? 0
            )
        }
        var found: [(target: String?, result: Result<[Checkout], Error>)] = []
        await withTaskGroup(of: (String?, Result<[Checkout], Error>).self) { group in
            for target in targets {
                group.addTask {
                    let result = await Task.detached(priority: .utility) {
                        Result { try Self.findCheckouts(host: target) }
                    }.value
                    return (target, result)
                }
            }
            for await (target, result) in group { found.append((target, result)) }
        }

        var all: [Checkout] = []
        for target in targets {
            guard let entry = found.first(where: { $0.target == target }) else { continue }
            switch entry.result {
            case .success(let checkouts):
                states[target] = HostScanState(
                    lastScan: Date(),
                    lastAttempt: states[target]?.lastAttempt,
                    repositoryCount: checkouts.count,
                    isTruncated: checkouts.count >= Self.scanLimit
                )
                all += checkouts
                discovered.removeAll { $0.host == target }
                discovered += checkouts
            case .failure(let error):
                states[target] = HostScanState(
                    lastScan: states[target]?.lastScan,
                    lastAttempt: states[target]?.lastAttempt,
                    repositoryCount: states[target]?.repositoryCount ?? 0,
                    error: Self.message(for: error)
                )
            }
        }
        persistDiscoveries()
        return all
    }

    private func persistDiscoveries() {
        guard persistenceEnabled else { return }
        if let data = try? JSONEncoder().encode(discovered) {
            defaults.set(data, forKey: discoveredKey)
        }
        var dates: [String: Date] = [:]
        for (target, state) in states {
            if let lastScan = state.lastScan { dates[target ?? ""] = lastScan }
        }
        defaults.set(dates, forKey: scanDatesKey)
    }

    /// Lists the repositories under the home folder and reads their origins.
    /// Blocks on `find` and `ssh`, so call it off the main thread.
    nonisolated static func findCheckouts(host: String?) throws -> [Checkout] {
        let output: Data
        if let host {
            output = try GitClient.runSSH(
                host: host,
                command: SSHBrowserRemote.repositoryScanCommand(limit: scanLimit)
            )
        } else {
            output = try runLocalScan()
        }
        let paths = SSHBrowserRemote.parseSuggestions(output)
        var origins: [String: String] = [:]
        for start in stride(from: 0, to: paths.count, by: statusBatchSize) {
            let batch = Array(paths[start..<min(start + statusBatchSize, paths.count)])
            for (path, result) in GitClient.checkoutStatuses(host: host, paths: batch) {
                if case .success(let status) = result, let origin = status.origin {
                    origins[path] = origin
                }
            }
        }
        return paths.map { Checkout(host: host, path: $0, origin: origins[$0]) }
    }

    private nonisolated static func runLocalScan() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SSHBrowserRemote.repositoryScanScript(limit: scanLimit)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    private static func message(for error: Error) -> String {
        if let error = error as? GitCommandError {
            let output = error.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty { return output }
        }
        return error.localizedDescription
    }
}

/// Lists scan results with a checkbox per repository. Nothing reaches the
/// registry until the user confirms.
struct ScanReviewSheet: View {
    let review: ScanReview
    @ObservedObject var registry: CheckoutRegistry
    let dismiss: () -> Void

    @State private var selection: Set<Checkout.ID>

    init(review: ScanReview, registry: CheckoutRegistry, dismiss: @escaping () -> Void) {
        self.review = review
        self.registry = registry
        self.dismiss = dismiss
        _selection = State(initialValue: Set(review.candidates.filter(\.isPreselected).map(\.id)))
    }

    private var machines: [(name: String, candidates: [ScanCandidate])] {
        var order: [String] = []
        var groups: [String: [ScanCandidate]] = [:]
        for candidate in review.candidates {
            let name = candidate.checkout.machineName
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(candidate)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private var newSelectionCount: Int {
        review.candidates.filter { !$0.isRegistered && selection.contains($0.id) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Found \(review.candidates.count) repositories")
                .font(AppType.sectionTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            Divider().overlay(AppTheme.edge)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(machines, id: \.name) { machine in
                        Section {
                            ForEach(machine.candidates) { row($0) }
                        } header: {
                            Text(machine.name)
                                .font(AppType.captionEmphasis)
                                .foregroundStyle(AppTheme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(AppTheme.canvas)
                        }
                    }
                }
            }
            Divider().overlay(AppTheme.edge)
            HStack {
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(newSelectionCount == 1 ? "Add 1 Checkout" : "Add \(newSelectionCount) Checkouts") {
                    for candidate in review.candidates
                    where candidate.isRegistered || selection.contains(candidate.id) {
                        registry.register(candidate.checkout)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newSelectionCount == 0)
            }
            .padding(16)
        }
        .frame(width: 640, height: 480)
        .background(AppTheme.canvas)
        .foregroundStyle(AppTheme.primary)
    }

    private func row(_ candidate: ScanCandidate) -> some View {
        Toggle(isOn: Binding(
            get: { selection.contains(candidate.id) },
            set: { isOn in
                if isOn { selection.insert(candidate.id) } else { selection.remove(candidate.id) }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(candidate.checkout.name).font(AppType.rowEmphasis)
                    if candidate.isRegistered {
                        Text("Already added")
                            .font(AppType.caption)
                            .foregroundStyle(AppTheme.secondary)
                    } else if let note = candidate.matchNote {
                        Text(note)
                            .font(AppType.caption)
                            .foregroundStyle(AppTheme.actionBlue)
                    }
                }
                Text(candidate.checkout.path)
                    .font(AppType.rowDetail)
                    .foregroundStyle(AppTheme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let origin = candidate.checkout.origin {
                    Text(origin)
                        .font(AppType.caption)
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(1)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(candidate.isRegistered)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

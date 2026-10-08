import XCTest
@testable import Kvist

final class RepositoryOverviewTests: XCTestCase {
    private func status(
        branch: String = "main", ahead: Int = 0, behind: Int = 0,
        upstream: Bool = true, changes: Int = 0
    ) -> CheckoutStatus {
        CheckoutStatus(
            branch: branch, ahead: ahead, behind: behind, hasUpstream: upstream,
            changeCount: changes, origin: nil, updatedAt: Date()
        )
    }

    func testPullDecisionAllowsOnlyCleanBehindBranchWithUpstream() {
        let decide = RepositoryOverviewLogic.pullDecision
        XCTAssertEqual(decide(status(behind: 2), nil), .pull)
        XCTAssertEqual(decide(status(behind: 2, changes: 1), nil), .skip("has uncommitted changes"))
        XCTAssertEqual(decide(status(behind: 2, upstream: false), nil), .skip("no upstream branch"))
        XCTAssertEqual(decide(status(ahead: 1, behind: 2), nil), .skip("diverged from upstream"))
        XCTAssertEqual(decide(status(ahead: 1), nil), .skip("already up to date"))
        XCTAssertEqual(decide(status(), nil), .skip("already up to date"))
        XCTAssertEqual(decide(nil, nil), .skip("status unknown"))
        XCTAssertEqual(decide(status(behind: 2), "timed out"), .skip("unreachable (timed out)"))
    }

    func testSummaryCountsAndOmitsZeros() {
        let results: [CheckoutActionResult] = [
            .pulled, .pulled, .skipped("x"), .failed("y"), .pulled
        ]
        XCTAssertEqual(
            RepositoryOverviewLogic.summary(verb: "Pulled", results: results),
            "Pulled 3, skipped 1, failed 1"
        )
        XCTAssertEqual(
            RepositoryOverviewLogic.summary(verb: "Fetched", results: [.fetched]),
            "Fetched 1"
        )
        XCTAssertEqual(RepositoryOverviewLogic.summary(verb: "Fetched", results: []), "Nothing to do")
    }

    func testSectionsGroupByOriginAndSort() {
        let origin = "github.com/me/zeta"
        let checkouts = [
            Checkout(host: "one-m", path: "/code/zeta", origin: origin),
            Checkout(host: nil, path: "/Users/me/zeta", origin: origin),
            Checkout(host: "depressed-louis", path: "/code/zeta", origin: origin),
            Checkout(host: nil, path: "/Users/me/Alpha", origin: nil),
            Checkout(host: nil, path: "/Users/me/alpha-two", origin: "github.com/me/beta")
        ]
        let sections = RepositoryOverviewLogic.sections(checkouts: checkouts, statuses: [:])
        XCTAssertEqual(sections.map(\.title), ["Alpha", "beta", "zeta"])
        XCTAssertNil(sections[0].origin)
        XCTAssertEqual(
            sections[2].checkouts.map(\.host),
            [nil, "depressed-louis", "one-m"]
        )
    }

    func testSectionsFilterByNameHostAndBranch() {
        let a = Checkout(host: nil, path: "/Users/me/kvist", origin: "github.com/me/kvist")
        let b = Checkout(host: "devbox", path: "/srv/other", origin: nil)
        let statuses = [b.id: status(branch: "feature/login")]
        func titles(_ query: String) -> [String] {
            RepositoryOverviewLogic.sections(checkouts: [a, b], statuses: statuses, query: query)
                .map(\.title)
        }
        XCTAssertEqual(titles(""), ["kvist", "other"])
        XCTAssertEqual(titles("KVI"), ["kvist"])
        XCTAssertEqual(titles("devbox"), ["other"])
        XCTAssertEqual(titles("login"), ["other"])
        XCTAssertEqual(titles("nothing"), [])
    }

    @MainActor
    func testPullAllFastForwardsOnlyCleanBehindCheckouts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("overview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String], in dir: URL? = nil) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "user.name=T", "-c", "user.email=t@example.com"] + args
            process.currentDirectoryURL = dir ?? root
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, args.joined(separator: " "))
        }
        func commit(_ name: String, in dir: URL) throws {
            try name.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            try git(["add", name], in: dir)
            try git(["commit", "-m", name], in: dir)
        }
        let remote = root.appendingPathComponent("remote.git")
        try git(["init", "--bare", "-b", "main", remote.path])
        let seed = root.appendingPathComponent("seed")
        try git(["clone", remote.path, seed.path])
        try commit("first", in: seed)
        try git(["push", "origin", "HEAD:main"], in: seed)
        var clones: [String: URL] = [:]
        for name in ["clean", "dirty", "diverged"] {
            let url = root.appendingPathComponent(name)
            try git(["clone", remote.path, url.path])
            clones[name] = url
        }
        try commit("second", in: seed)
        try git(["push", "origin", "HEAD:main"], in: seed)
        try "x".write(to: clones["dirty"]!.appendingPathComponent("first"), atomically: true, encoding: .utf8)
        try commit("local", in: clones["diverged"]!)

        let defaults = UserDefaults(suiteName: "RepositoryOverviewTests-\(UUID().uuidString)")!
        let tabs = WorkspaceTabsModel(defaults: defaults, restoreSavedTabs: false)
        let registry = CheckoutRegistry(defaults: defaults, persistenceEnabled: false)
        let checkouts = ["clean", "dirty", "diverged"].map {
            Checkout(host: nil, path: clones[$0]!.path)
        }
        checkouts.forEach(registry.register)
        let model = RepositoryOverviewModel()
        await model.pull(checkouts, registry: registry, tabs: tabs)

        XCTAssertEqual(model.results[checkouts[0].id], .pulled)
        XCTAssertEqual(model.results[checkouts[1].id], .skipped("has uncommitted changes"))
        XCTAssertEqual(model.results[checkouts[2].id], .skipped("diverged from upstream"))
        XCTAssertEqual(model.summary, "Pulled 1, skipped 2")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: clones["clean"]!.appendingPathComponent("second").path))
        XCTAssertEqual(registry.statuses[checkouts[0].id]?.behind, 0)
    }
}

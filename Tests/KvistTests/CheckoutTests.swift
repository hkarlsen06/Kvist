import XCTest
@testable import Kvist

final class CheckoutTests: XCTestCase {
    func testNormalizedOriginMatchesURLFormsOfOneRepository() {
        let forms = [
            "git@github.com:Me/Kvist.git",
            "https://github.com/me/kvist",
            "https://github.com/me/kvist.git/",
            "ssh://git@github.com:22/me/kvist.git",
            "github.com:me/kvist"
        ]
        for form in forms {
            XCTAssertEqual(Checkout.normalizedOrigin(form), "github.com/me/kvist", form)
        }
    }

    func testNormalizedOriginKeepsCaseOnGenericServers() {
        XCTAssertEqual(Checkout.normalizedOrigin("git@Server:Team/X.git"), "server/Team/X")
        XCTAssertNotEqual(
            Checkout.normalizedOrigin("git@server:Team/X.git"),
            Checkout.normalizedOrigin("git@server:team/x.git")
        )
    }

    func testNormalizedOriginRejectsLocalPaths() {
        XCTAssertNil(Checkout.normalizedOrigin("/srv/git/kvist.git"))
        XCTAssertNil(Checkout.normalizedOrigin("file:///srv/git/kvist.git"))
        XCTAssertNil(Checkout.normalizedOrigin("./a:b"))
        XCTAssertNil(Checkout.normalizedOrigin(""))
    }

    @MainActor
    func testRegisterKeepsKnownOriginAndGroupsByOrigin() {
        let defaults = UserDefaults(suiteName: "CheckoutTests-\(UUID().uuidString)")!
        let registry = CheckoutRegistry(defaults: defaults)
        registry.register(Checkout(host: nil, path: "/code/kvist", origin: "github.com/me/kvist"))
        registry.register(Checkout(host: "devbox", path: "/srv/kvist", origin: "github.com/me/kvist"))
        registry.register(Checkout(host: nil, path: "/code/other"))
        registry.register(Checkout(host: nil, path: "/code/kvist"))

        XCTAssertEqual(
            registry.checkouts(sameRepositoryAs: Checkout(host: nil, path: "/code/kvist")).map(\.id),
            [":/code/kvist", "devbox:/srv/kvist"]
        )
        XCTAssertEqual(CheckoutRegistry(defaults: defaults).checkouts.count, 3)
    }

    func testLocalCheckoutStatusReadsBranchChangesAndOrigin() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckoutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = GitClient(repositoryURL: directory)
        _ = try client.run(["init", "-b", "main"])
        _ = try client.run(["remote", "add", "origin", "git@github.com:me/kvist.git"])
        try "a".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let results = GitClient.checkoutStatuses(
            host: nil,
            paths: [directory.path, "/missing/kvist", nested.path]
        )
        let status = try XCTUnwrap(try results[directory.path]?.get())
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.changeCount, 1)
        XCTAssertEqual(status.origin, "github.com/me/kvist")
        XCTAssertThrowsError(try results["/missing/kvist"]?.get())
        XCTAssertThrowsError(try results[nested.path]?.get())
    }

    func testPickerGroupsClonesAndPutsRecentFirst() {
        let local = Checkout(host: nil, path: "/code/kvist", origin: "github.com/me/kvist")
        let remote = Checkout(host: "devbox", path: "/srv/kvist", origin: "github.com/me/kvist")
        let other = Checkout(host: "devbox", path: "/srv/alpha", origin: "github.com/me/alpha")
        let loose = Checkout(host: nil, path: "/code/notes")

        let list = PickerRepository.list(
            recent: [Checkout(host: "devbox", path: "/srv/kvist")],
            known: [local, remote, other, loose]
        )

        XCTAssertEqual(list.map(\.name), ["kvist", "alpha", "notes"])
        XCTAssertEqual(list[0].checkouts.map(\.id), [local.id, remote.id])
        // The recent checkout opens on a click, even though it is remote.
        XCTAssertEqual(list[0].preferred.id, remote.id)
        XCTAssertEqual(list[0].label(for: remote), "devbox")
        XCTAssertEqual(PickerRepository.list(recent: [], known: [local, remote, other], query: "alp").map(\.name), ["alpha"])
        XCTAssertEqual(PickerRepository.list(recent: [], known: [local, remote], query: "devbox").count, 1)

        let folder = Checkout(host: nil, path: "/other/kvist")
        let named = PickerRepository.list(recent: [], known: [local, folder])
        XCTAssertEqual(named.map { $0.label(for: $0.checkouts[0]) }, ["This Mac · /code", "This Mac · /other"])
        XCTAssertTrue(PickerRepository.isGone("fatal: cannot change to '/srv/x': No such file or directory"))
        XCTAssertFalse(PickerRepository.isGone("ssh: connect to host devbox port 22: Operation timed out"))
    }

    @MainActor
    func testHostsModelKeepsDiscoveriesAcrossLaunches() {
        let defaults = UserDefaults(suiteName: "CheckoutTests-\(UUID().uuidString)")!
        defaults.set(["devbox"], forKey: "sshHosts")
        let found = [Checkout(host: "devbox", path: "/srv/kvist", origin: "github.com/me/kvist")]
        defaults.set(try? JSONEncoder().encode(found), forKey: "discoveredCheckouts")
        defaults.set(["devbox": Date(), "": Date()], forKey: "machineScanDates")

        let model = SSHHostsModel(defaults: defaults)
        XCTAssertEqual(model.hosts, ["devbox"])
        XCTAssertEqual(model.discovered, found)
        XCTAssertNotNil(model.states["devbox"]?.lastScan)
        XCTAssertNotNil(model.states[nil]?.lastScan)

        model.remove("devbox")
        XCTAssertTrue(SSHHostsModel(defaults: defaults).discovered.isEmpty)
    }
}

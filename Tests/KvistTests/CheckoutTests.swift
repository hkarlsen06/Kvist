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

        let results = GitClient.checkoutStatuses(host: nil, paths: [directory.path, "/missing/kvist"])
        let status = try XCTUnwrap(try results[directory.path]?.get())
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.changeCount, 1)
        XCTAssertEqual(status.origin, "github.com/me/kvist")
        XCTAssertThrowsError(try results["/missing/kvist"]?.get())
    }
}

import XCTest
@testable import Kvist

final class SSHHostsTests: XCTestCase {
    func testConfigHostsSkipPatternsAndRepeats() {
        let config = """
        # personal hosts
        Host dev mdr
            HostName 10.0.0.2
        Host one-s 100.109.207.90
        host=one-m
        Host depressed-louis
        Host dev
        Host *.internal !bastion web?
        Host *
        HostName not-a-host
        Hostile x
        """
        XCTAssertEqual(SSHConfigHosts.hosts(in: config), [
            "dev", "mdr", "one-s", "100.109.207.90", "one-m", "depressed-louis"
        ])
    }

    func testAnnotateMarksRegisteredAndMatchingCheckouts() {
        let origin = "github.com/me/ampoteket"
        let registered = [
            Checkout(host: nil, path: "/Users/me/code/ampoteket", origin: origin),
            Checkout(host: "dev", path: "/home/me/other", origin: "github.com/me/other")
        ]
        let found = [
            Checkout(host: "dev", path: "/home/me/ampoteket", origin: origin),
            Checkout(host: "dev", path: "/home/me/other", origin: "github.com/me/other"),
            Checkout(host: "dev", path: "/home/me/new", origin: "github.com/me/new"),
            Checkout(host: "dev", path: "/home/me/scratch", origin: nil)
        ]
        let candidates = ScanCandidate.annotate(found: found, registered: registered)

        XCTAssertEqual(candidates.map(\.isRegistered), [false, true, false, false])
        XCTAssertEqual(candidates[0].matchNote, "Matches ampoteket on This Mac")
        XCTAssertEqual(candidates.map(\.isPreselected), [true, true, false, false])
        XCTAssertNil(candidates[3].match)
    }

    func testScanCommandIsOneQuotedPOSIXScript() {
        let script = SSHBrowserRemote.repositoryScanScript(limit: 200)
        XCTAssertTrue(script.contains("head -n 200"))
        XCTAssertTrue(script.contains("-name node_modules"))
        XCTAssertFalse(script.contains("\\\n"), "line continuations must reach sh as plain text")
        XCTAssertTrue(SSHBrowserRemote.repositoryScanCommand(limit: 5).hasPrefix("/bin/sh -c '"))
    }

    func testScanFindsRepositoriesAndSkipsHiddenFoldersAndNodeModules() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("hosts-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let folders = [
            "code/app/.git", "code/.hidden/x/.git", "code/web/node_modules/pkg/.git",
            "Library/y/.git", "code/linked"
        ]
        for folder in folders {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(folder), withIntermediateDirectories: true
            )
        }
        // A linked worktree has a .git file instead of a folder.
        try Data().write(to: home.appendingPathComponent("code/linked/.git"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SSHBrowserRemote.repositoryScanScript(limit: 200)]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let paths = SSHBrowserRemote.parseSuggestions(data)
            .map { $0.replacingOccurrences(of: home.path, with: "") }
        XCTAssertEqual(paths, ["/code/app", "/code/linked"])
    }
}

import XCTest
@testable import Kvist

final class SSHMirrorStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KvistMirrors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeMirror(_ id: String, name: String = "repo") throws -> URL {
        let mirror = root.appendingPathComponent("\(id)/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mirror.appendingPathComponent("src"),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: mirror.appendingPathComponent(SSHMirrorStore.markerName))
        try Data("code".utf8).write(to: mirror.appendingPathComponent("src/main.swift"))
        return mirror.standardizedFileURL
    }

    private func contents(of url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    func testClosingATabKeepsOnlyTheMarker() throws {
        let mirror = try makeMirror("a")

        SSHMirrorStore.removeDownloads(at: mirror, root: root)

        XCTAssertEqual(contents(of: mirror), [SSHMirrorStore.markerName])
    }

    func testRemoveDownloadsIgnoresFoldersOutsideTheMirrorRoot() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("KvistNotAMirror-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: outside.appendingPathComponent(SSHMirrorStore.markerName))
        try Data("keep".utf8).write(to: outside.appendingPathComponent("file.txt"))

        SSHMirrorStore.removeDownloads(at: outside, root: root)

        XCTAssertEqual(contents(of: outside), [SSHMirrorStore.markerName, "file.txt"])
    }

    func testLaunchSweepKeepsOpenTrimsRecentAndDeletesTheRest() throws {
        let open = try makeMirror("open")
        let recent = try makeMirror("recent")
        _ = try makeMirror("orphan")

        SSHMirrorStore.removeUnused(
            keepingOpen: [open.path],
            recent: [recent.path],
            root: root
        )

        XCTAssertEqual(contents(of: root), ["open", "recent"])
        XCTAssertEqual(contents(of: open), [SSHMirrorStore.markerName, "src"])
        XCTAssertEqual(contents(of: recent), [SSHMirrorStore.markerName])
    }
}

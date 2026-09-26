import Foundation
import XCTest
@testable import Kvist

final class AppUpdaterTests: XCTestCase {
    func testVersionComparisonIsNumeric() {
        XCTAssertTrue(AppUpdater.isNewer("0.10.0", than: "0.9.3"))
        XCTAssertTrue(AppUpdater.isNewer("0.3.2", than: "0.3.1"))
        XCTAssertFalse(AppUpdater.isNewer("0.3.1", than: "0.3.1"))
        XCTAssertFalse(AppUpdater.isNewer("0.2.9", than: "0.3.0"))
    }

    func testNewestReleaseIgnoresOtherPlatformsPrereleasesAndMissingArchives() throws {
        let json = """
        [
          {"tag_name": "ios/9.0.0", "draft": false, "prerelease": false,
           "assets": [{"name": "Kvist.zip", "browser_download_url": "https://example.com/ios.zip"}]},
          {"tag_name": "macos/0.5.0", "draft": false, "prerelease": true,
           "assets": [{"name": "Kvist.zip", "browser_download_url": "https://example.com/beta.zip"}]},
          {"tag_name": "macos/0.4.1", "draft": false, "prerelease": false,
           "assets": [{"name": "Kvist.dmg", "browser_download_url": "https://example.com/Kvist.dmg"}]},
          {"tag_name": "macos/0.3.1", "draft": false, "prerelease": false, "body": "Notes",
           "assets": [{"name": "Kvist.zip", "browser_download_url": "https://example.com/0.3.1.zip",
                       "digest": "sha256:abc"}]},
          {"tag_name": "macos/0.10.0", "draft": false, "prerelease": false,
           "assets": [{"name": "Kvist.zip", "browser_download_url": "https://example.com/0.10.0.zip"}]}
        ]
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let releases = try decoder.decode(
            [AppUpdater.Release].self,
            from: Data(json.utf8)
        )

        let newest = AppUpdater.newestRelease(in: releases)
        XCTAssertEqual(newest?.version, "0.10.0")
        XCTAssertEqual(
            newest?.archive?.browserDownloadUrl,
            URL(string: "https://example.com/0.10.0.zip")
        )
    }

    func testReleaseNotesSummaryDropsHeadingsAndDownloadInstructions() {
        let headed = """
        Kvist 0.3.0 adds remote folders.

        ## Highlights

        - Open any folder over SSH.

        ## Requirements

        - macOS 26 or later.

        SHA-256:
        - `Kvist.zip`: `abc`
        """
        XCTAssertEqual(
            AppUpdater.releaseNotesSummary(headed),
            "Kvist 0.3.0 adds remote folders.\n\n- Open any folder over SSH."
        )

        let plain = """
        Kvist 0.3.1 improves previews.

        - WebP previews work.

        Requires macOS 26 or later. Download `Kvist.dmg`.

        SHA-256:
        """
        XCTAssertEqual(
            AppUpdater.releaseNotesSummary(plain),
            "Kvist 0.3.1 improves previews.\n\n- WebP previews work."
        )
    }
}

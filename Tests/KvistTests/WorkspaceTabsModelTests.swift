import Combine
import Foundation
import XCTest
@testable import Kvist

@MainActor
final class WorkspaceTabsModelTests: XCTestCase {
    func testNewTabsUseIndependentRepositoryModelsAndCanBeClosed() {
        let defaults = isolatedDefaults()
        let tabsModel = WorkspaceTabsModel(
            defaults: defaults,
            restoreSavedTabs: false
        )
        let firstTab = tabsModel.activeTab

        tabsModel.addTab()

        XCTAssertEqual(tabsModel.tabs.count, 2)
        XCTAssertNotEqual(tabsModel.activeTabID, firstTab.id)
        XCTAssertFalse(tabsModel.activeModel === firstTab.model)
        XCTAssertNil(tabsModel.activeModel.repositoryURL)

        tabsModel.close(tabsModel.activeTabID)

        XCTAssertEqual(tabsModel.tabs.count, 1)
        XCTAssertEqual(tabsModel.activeTabID, firstTab.id)
    }

    func testMoveTabReordersClampsAndPersists() {
        let defaults = isolatedDefaults()
        let tabsModel = WorkspaceTabsModel(
            defaults: defaults,
            restoreSavedTabs: false
        )
        tabsModel.addTab()
        tabsModel.addTab()
        let originalIDs = tabsModel.tabs.map(\.id)

        tabsModel.moveTab(originalIDs[0], toIndex: 2)

        XCTAssertEqual(
            tabsModel.tabs.map(\.id),
            [originalIDs[1], originalIDs[2], originalIDs[0]]
        )

        // Out-of-range destinations clamp instead of dropping the tab.
        tabsModel.moveTab(originalIDs[0], toIndex: 99)
        XCTAssertEqual(tabsModel.tabs.last?.id, originalIDs[0])
        tabsModel.moveTab(originalIDs[0], toIndex: -5)
        XCTAssertEqual(tabsModel.tabs.first?.id, originalIDs[0])
        XCTAssertEqual(Set(tabsModel.tabs.map(\.id)), Set(originalIDs))

        // Unknown tabs and no-op moves leave the order untouched.
        let reordered = tabsModel.tabs.map(\.id)
        tabsModel.moveTab(UUID(), toIndex: 0)
        tabsModel.moveTab(reordered[1], toIndex: 1)
        XCTAssertEqual(tabsModel.tabs.map(\.id), reordered)
    }

    func testEditingAfterDocumentIsDirtyDoesNotInvalidateWorkspaceChrome() {
        let tabsModel = WorkspaceTabsModel(
            defaults: isolatedDefaults(),
            restoreSavedTabs: false
        )
        var workspaceChanges = 0
        let subscription = tabsModel.objectWillChange.sink {
            workspaceChanges += 1
        }

        tabsModel.activeModel.repositoryFileText = "first edit"
        XCTAssertGreaterThan(workspaceChanges, 0)

        workspaceChanges = 0
        tabsModel.activeModel.repositoryFileText = "second edit"

        XCTAssertEqual(workspaceChanges, 0)
        withExtendedLifetime(subscription) {}
    }

    func testTypingCommitMessageDoesNotInvalidateWorkspaceChrome() {
        let tabsModel = WorkspaceTabsModel(
            defaults: isolatedDefaults(),
            restoreSavedTabs: false
        )
        var workspaceChanges = 0
        let subscription = tabsModel.objectWillChange.sink {
            workspaceChanges += 1
        }

        tabsModel.activeModel.commitMessage = "Update version"

        XCTAssertEqual(workspaceChanges, 0)
        XCTAssertEqual(tabsModel.activeModel.commitMessage, "Update version")
        withExtendedLifetime(subscription) {}
    }

    func testTracksUnsavedFileChangesAcrossTabs() async throws {
        let repositoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repositoryURL) }
        try GitClient.initializeRepository(
            at: repositoryURL,
            createGitIgnore: false
        )
        try "saved\n".write(
            to: repositoryURL.appendingPathComponent("Version.txt"),
            atomically: true,
            encoding: .utf8
        )
        let tabsModel = WorkspaceTabsModel(
            defaults: isolatedDefaults(),
            restoreSavedTabs: false
        )
        await tabsModel.activeModel.openRepository(repositoryURL)
        tabsModel.activeModel.setWorkspaceMode(.fileEditor)
        tabsModel.activeModel.openRepositoryFile("Version.txt")
        let deadline = Date().addingTimeInterval(3)
        while tabsModel.activeModel.isDetailLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(tabsModel.hasUnsavedRepositoryFileChanges)

        tabsModel.activeModel.repositoryFileText = "unsaved"

        XCTAssertTrue(tabsModel.hasUnsavedRepositoryFileChanges)
    }

    func testRestoresWorkspaceModeExpandedFoldersCommitTextAndDraft() async throws {
        let defaults = isolatedDefaults()
        let repositoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repositoryURL) }
        try GitClient.initializeRepository(at: repositoryURL, createGitIgnore: false)
        let sourceDirectory = repositoryURL.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        try "saved\n".write(
            to: sourceDirectory.appendingPathComponent("State.txt"),
            atomically: true,
            encoding: .utf8
        )

        let original = WorkspaceTabsModel(
            defaults: defaults,
            restoreSavedTabs: false
        )
        await original.activeModel.openRepository(repositoryURL)
        original.activeModel.setWorkspaceMode(.fileEditor)
        original.activeModel.toggleFileDirectory("Sources")
        original.activeModel.openRepositoryFile("Sources/State.txt")
        await waitForEditor(in: original.activeModel)
        original.activeModel.repositoryFileText = "recovered draft\n"
        original.activeModel.commitMessage = "Keep this commit message"
        original.prepareForTermination()

        let restored = WorkspaceTabsModel(defaults: defaults)
        await waitForRepository(repositoryURL, in: restored.activeModel)
        let deadline = Date().addingTimeInterval(3)
        while restored.activeModel.selectedRepositoryFilePath != "Sources/State.txt",
              Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(restored.activeModel.workspaceMode, .fileEditor)
        XCTAssertTrue(restored.activeModel.expandedFileDirectories.contains("Sources"))
        XCTAssertEqual(restored.activeModel.selectedRepositoryFilePath, "Sources/State.txt")
        XCTAssertEqual(restored.activeModel.repositoryFileText, "recovered draft\n")
        XCTAssertTrue(restored.activeModel.repositoryFileDirty)
        XCTAssertEqual(restored.activeModel.commitMessage, "Keep this commit message")
    }

    func testClosingTheOnlyTabLeavesAnEmptyReplacementTab() {
        let defaults = isolatedDefaults()
        let tabsModel = WorkspaceTabsModel(
            defaults: defaults,
            restoreSavedTabs: false
        )
        let originalTabID = tabsModel.activeTabID

        tabsModel.close(originalTabID)

        XCTAssertEqual(tabsModel.tabs.count, 1)
        XCTAssertNotEqual(tabsModel.activeTabID, originalTabID)
        XCTAssertNil(tabsModel.activeModel.repositoryURL)
    }

    func testClosingLastRepositoryClearsLegacyRestorePath() throws {
        let defaults = isolatedDefaults()
        let repositoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repositoryURL) }
        defaults.set([repositoryURL.path], forKey: "openRepositoryPaths")
        defaults.set(repositoryURL.path, forKey: "activeRepositoryPath")
        defaults.set(repositoryURL.path, forKey: "lastRepositoryPath")
        let tabsModel = WorkspaceTabsModel(defaults: defaults)

        tabsModel.close(tabsModel.activeTabID)

        XCTAssertEqual(defaults.stringArray(forKey: "openRepositoryPaths"), [])
        XCTAssertNil(defaults.string(forKey: "activeRepositoryPath"))
        XCTAssertNil(defaults.string(forKey: "lastRepositoryPath"))

        let restoredModel = WorkspaceTabsModel(defaults: defaults)
        XCTAssertEqual(restoredModel.tabs.count, 1)
        XCTAssertNil(restoredModel.activeModel.repositoryURL)
    }

    func testRestoresAllSavedDirectoriesAndTheSelectedTab() throws {
        let defaults = isolatedDefaults()
        let firstURL = try temporaryDirectory()
        let secondURL = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        defaults.set(
            [firstURL.path, secondURL.path],
            forKey: "openRepositoryPaths"
        )
        defaults.set(secondURL.path, forKey: "activeRepositoryPath")

        let tabsModel = WorkspaceTabsModel(defaults: defaults)

        XCTAssertEqual(tabsModel.tabs.count, 2)
        XCTAssertEqual(tabsModel.activeTabID, tabsModel.tabs[1].id)
        XCTAssertEqual(
            defaults.stringArray(forKey: "openRepositoryPaths"),
            [firstURL.path, secondURL.path]
        )
    }

    func testRestoredInactiveTabLoadsOnlyWhenSelected() async throws {
        let defaults = isolatedDefaults()
        let firstURL = try temporaryDirectory()
        let secondURL = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        try GitClient.initializeRepository(at: firstURL, createGitIgnore: false)
        try GitClient.initializeRepository(at: secondURL, createGitIgnore: false)
        defaults.set(
            [firstURL.path, secondURL.path],
            forKey: "openRepositoryPaths"
        )
        defaults.set(secondURL.path, forKey: "activeRepositoryPath")

        let tabsModel = WorkspaceTabsModel(defaults: defaults)
        let firstTab = tabsModel.tabs[0]
        let secondTab = tabsModel.tabs[1]

        XCTAssertNil(firstTab.loadedModel)
        XCTAssertTrue(firstTab.isRepositoryLoadPending)
        XCTAssertTrue(secondTab.isRepositoryLoadPending)
        await waitForRepository(secondURL, in: secondTab.model)
        XCTAssertEqual(
            secondTab.model.repositoryURL?.resolvingSymlinksInPath(),
            secondURL.resolvingSymlinksInPath()
        )
        await waitForRepositoryLoad(in: secondTab)
        XCTAssertFalse(secondTab.isRepositoryLoadPending)
        XCTAssertEqual(firstTab.displayName, firstURL.lastPathComponent)

        tabsModel.select(firstTab.id)
        XCTAssertTrue(firstTab.isRepositoryLoadPending)
        await waitForRepository(firstURL, in: firstTab.model)

        XCTAssertEqual(
            firstTab.model.repositoryURL?.resolvingSymlinksInPath(),
            firstURL.resolvingSymlinksInPath()
        )
        await waitForRepositoryLoad(in: firstTab)
        XCTAssertFalse(firstTab.isRepositoryLoadPending)
        XCTAssertEqual(tabsModel.activeTabID, firstTab.id)
    }

    func testRestoredTabWithMissingFolderStaysAndLoadsWhenTheFolderReturns() async throws {
        let defaults = isolatedDefaults()
        let parentURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        let repositoryURL = parentURL.appendingPathComponent("repo", isDirectory: true)
        defaults.set([repositoryURL.path], forKey: "openRepositoryPaths")

        let tabsModel = WorkspaceTabsModel(defaults: defaults)
        let tab = tabsModel.activeTab

        XCTAssertEqual(tabsModel.tabs.count, 1)
        XCTAssertTrue(tab.isFolderMissing)
        XCTAssertFalse(tab.isRepositoryLoadPending)
        XCTAssertEqual(
            defaults.stringArray(forKey: "openRepositoryPaths"),
            [repositoryURL.path]
        )

        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try GitClient.initializeRepository(at: repositoryURL, createGitIgnore: false)
        tabsModel.retryMissingActiveTab()

        XCTAssertFalse(tab.isFolderMissing)
        await waitForRepository(repositoryURL, in: tab.model)
        XCTAssertEqual(
            tab.model.repositoryURL?.resolvingSymlinksInPath(),
            repositoryURL.resolvingSymlinksInPath()
        )
    }

    func testRestoredPlainFolderLeavesLoadingStateForRepositorySetup() async throws {
        let defaults = isolatedDefaults()
        let folderURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        defaults.set([folderURL.path], forKey: "openRepositoryPaths")

        let tabsModel = WorkspaceTabsModel(defaults: defaults)
        let tab = tabsModel.activeTab
        XCTAssertTrue(tab.isRepositoryLoadPending)

        let deadline = Date().addingTimeInterval(3)
        while tab.model.repositoryInitializationURL == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await waitForRepositoryLoad(in: tab)

        XCTAssertEqual(
            tab.model.repositoryInitializationURL?.standardizedFileURL,
            folderURL.standardizedFileURL
        )
        XCTAssertFalse(tab.isRepositoryLoadPending)
    }

    func testTwentyRestoredTabsStayLazyAndUseOnlyOneWatcher() async throws {
        let defaults = isolatedDefaults()
        let repositoryURLs = try (0..<20).map { _ in
            let url = try temporaryDirectory()
            try GitClient.initializeRepository(at: url, createGitIgnore: false)
            return url
        }
        defer {
            repositoryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        defaults.set(repositoryURLs.map(\.path), forKey: "openRepositoryPaths")
        defaults.set(repositoryURLs[0].path, forKey: "activeRepositoryPath")
        KvistRuntimeMetrics.reset()

        let tabsModel = WorkspaceTabsModel(
            defaults: defaults,
            automaticallyActivatesInitialTab: false
        )

        XCTAssertEqual(tabsModel.tabs.count, 20)
        XCTAssertNil(tabsModel.activeTab.loadedModel)
        XCTAssertTrue(tabsModel.activeTab.isRepositoryLoadPending)
        XCTAssertTrue(tabsModel.tabs.dropFirst().allSatisfy { $0.loadedModel == nil })
        XCTAssertEqual(tabsModel.activeRepositoryWatcherCount, 0)
        XCTAssertTrue(KvistRuntimeMetrics.snapshot().gitCommandsByRepository.isEmpty)

        tabsModel.activateInitialTab()
        XCTAssertTrue(tabsModel.activeTab.isRepositoryLoadPending)
        await waitForRepository(repositoryURLs[0], in: tabsModel.activeModel)
        await waitForWatcher(in: tabsModel)

        XCTAssertEqual(tabsModel.tabs.count { $0.loadedModel?.repositoryURL != nil }, 1)
        XCTAssertEqual(tabsModel.activeRepositoryWatcherCount, 1)
        let inactivePaths = Set(repositoryURLs.dropFirst().map { $0.standardizedFileURL.path })
        let inactiveCommands = KvistRuntimeMetrics.snapshot().gitCommandsByRepository.reduce(into: 0) {
            if inactivePaths.contains($1.key) { $0 += $1.value }
        }
        XCTAssertEqual(inactiveCommands, 0)

        for (tab, repositoryURL) in zip(tabsModel.tabs.dropFirst(), repositoryURLs.dropFirst()) {
            tabsModel.select(tab.id)
            await waitForRepository(repositoryURL, in: tab.model)
            await waitForWatcher(in: tabsModel)
            XCTAssertEqual(tabsModel.activeRepositoryWatcherCount, 1)
        }

        tabsModel.activeModel.setMonitoringEnabled(false)
        XCTAssertEqual(tabsModel.activeRepositoryWatcherCount, 0)
    }

    func testReactivatedTabCatchesFilesystemChangesFromWhileInactive() async throws {
        let defaults = isolatedDefaults()
        let firstURL = try temporaryDirectory()
        let secondURL = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        try GitClient.initializeRepository(at: firstURL, createGitIgnore: false)
        try GitClient.initializeRepository(at: secondURL, createGitIgnore: false)
        defaults.set([firstURL.path, secondURL.path], forKey: "openRepositoryPaths")
        defaults.set(firstURL.path, forKey: "activeRepositoryPath")
        let tabsModel = WorkspaceTabsModel(defaults: defaults)
        let firstTab = tabsModel.tabs[0]
        let secondTab = tabsModel.tabs[1]
        await waitForRepository(firstURL, in: firstTab.model)

        tabsModel.select(secondTab.id)
        await waitForRepository(secondURL, in: secondTab.model)
        try await Task.sleep(for: .milliseconds(50))
        try "changed while inactive\n".write(
            to: firstURL.appendingPathComponent("inactive-change.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await Task.sleep(for: .milliseconds(50))

        tabsModel.select(firstTab.id)
        let deadline = Date().addingTimeInterval(3)
        while !firstTab.model.unstaged.contains(where: { $0.path == "inactive-change.txt" }),
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(
            firstTab.model.unstaged.contains { $0.path == "inactive-change.txt" }
        )
        XCTAssertEqual(tabsModel.activeRepositoryWatcherCount, 1)
        firstTab.model.setMonitoringEnabled(false)
    }

    func testSelectNextAndPreviousCycleThroughTabs() {
        let tabsModel = WorkspaceTabsModel(
            defaults: isolatedDefaults(),
            restoreSavedTabs: false
        )
        tabsModel.addTab()
        tabsModel.addTab()
        let tabIDs = tabsModel.tabs.map(\.id)
        tabsModel.select(tabIDs[0])

        tabsModel.selectNext()
        XCTAssertEqual(tabsModel.activeTabID, tabIDs[1])

        tabsModel.selectPrevious()
        tabsModel.selectPrevious()
        XCTAssertEqual(tabsModel.activeTabID, tabIDs[2])

        tabsModel.selectNext()
        XCTAssertEqual(tabsModel.activeTabID, tabIDs[0])
    }

    func testSwitchingToWorktreeReusesItsTabOrOpensOneAfterTheActiveTab() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let main = root.appendingPathComponent("main", isDirectory: true)
        let other = root.appendingPathComponent("other", isDirectory: true)
        let feature = root.appendingPathComponent("feature", isDirectory: true)
        let tabsModel = WorkspaceTabsModel(
            defaults: isolatedDefaults(),
            restoredRepositoryURLs: [main, other],
            persistenceEnabled: false
        )
        let tabIDs = tabsModel.tabs.map(\.id)

        tabsModel.switchToWorktree(GitWorktree(path: other.path, branch: "other"))
        XCTAssertEqual(tabsModel.activeTabID, tabIDs[1])
        XCTAssertEqual(tabsModel.tabs.count, 2)

        tabsModel.select(tabIDs[0])
        tabsModel.switchToWorktree(GitWorktree(path: feature.path, branch: "feature"))
        XCTAssertEqual(tabsModel.tabs.count, 3)
        XCTAssertEqual(tabsModel.tabs[1].repositoryURL?.path, feature.path)
        XCTAssertEqual(tabsModel.activeTabID, tabsModel.tabs[1].id)
    }

    func testSwitchingToSSHWorktreeFindsTheTabShowingThatRemotePath() throws {
        let mirror = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mirror) }
        try JSONEncoder().encode(SSHRepository(host: "example", path: "/srv/feature"))
            .write(to: mirror.appendingPathComponent(SSHMirrorStore.markerName))
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tabsModel = WorkspaceTabsModel(
            defaults: isolatedDefaults(),
            restoredRepositoryURLs: [mirror, local],
            persistenceEnabled: false,
            automaticallyActivatesInitialTab: false
        )
        let mirrorTabID = tabsModel.tabs[0].id

        tabsModel.switchToWorktree(
            GitWorktree(path: "/srv/feature", branch: "feature", sshHost: "example")
        )

        XCTAssertEqual(tabsModel.tabs.count, 2)
        XCTAssertEqual(tabsModel.activeTabID, mirrorTabID)
    }

    func testRemovingTheActiveWorktreeClosesItsTabAndShowsTheMainWorktree() async throws {
        let mainURL = try temporaryDirectory()
        let linkedURL = mainURL.deletingLastPathComponent()
            .appendingPathComponent(mainURL.lastPathComponent + "-linked", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: mainURL)
            try? FileManager.default.removeItem(at: linkedURL)
        }
        try GitClient.initializeRepository(at: mainURL, createGitIgnore: false)
        let client = GitClient(repositoryURL: mainURL)
        _ = try client.run([
            "-c", "user.name=Kvist Test", "-c", "user.email=kvist@example.invalid",
            "commit", "--allow-empty", "-m", "Initial"
        ])
        try client.addWorktree(path: linkedURL.path, branch: "feature")
        let tabsModel = WorkspaceTabsModel(
            defaults: isolatedDefaults(),
            restoredRepositoryURLs: [mainURL, linkedURL],
            persistenceEnabled: false
        )
        let mainTab = tabsModel.tabs[0]
        let linkedTab = tabsModel.tabs[1]
        tabsModel.select(linkedTab.id)
        await waitForRepositoryLoad(in: linkedTab)
        let linked = try XCTUnwrap(linkedTab.model.worktrees.first { $0.branch == "feature" })
        let linkedID = Checkout(worktree: linked).id
        let registered = Date().addingTimeInterval(5)
        while tabsModel.checkoutRegistry.checkout(id: linkedID) == nil, Date() < registered {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNotNil(tabsModel.checkoutRegistry.checkout(id: linkedID))

        await tabsModel.removeWorktree(linked)
        let deadline = Date().addingTimeInterval(5)
        while tabsModel.tabs.count > 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(tabsModel.tabs.map(\.id), [mainTab.id])
        XCTAssertEqual(tabsModel.activeTabID, mainTab.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: linkedURL.path))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(tabsModel.checkoutRegistry.checkout(id: linkedID))
    }

    func testWorktreeTabsShareOneTopLevelEntryThatMovesClosesAndRestoresTogether() async throws {
        let mainURL = try temporaryDirectory()
        let linkedURL = mainURL.deletingLastPathComponent()
            .appendingPathComponent(mainURL.lastPathComponent + "-linked", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: mainURL)
            try? FileManager.default.removeItem(at: linkedURL)
        }
        try GitClient.initializeRepository(at: mainURL, createGitIgnore: false)
        let client = GitClient(repositoryURL: mainURL)
        _ = try client.run([
            "-c", "user.name=Kvist Test", "-c", "user.email=kvist@example.invalid",
            "commit", "--allow-empty", "-m", "Initial"
        ])
        try client.addWorktree(path: linkedURL.path, branch: "feature")
        let defaults = isolatedDefaults()
        let tabsModel = WorkspaceTabsModel(
            defaults: defaults,
            restoredRepositoryURLs: [mainURL]
        )
        let mainTab = tabsModel.activeTab
        await waitForRepositoryLoad(in: mainTab)
        XCTAssertEqual(mainTab.worktrees.count, 2)
        let linked = try XCTUnwrap(mainTab.worktrees.first { $0.branch == "feature" })

        tabsModel.switchToWorktree(linked)
        let linkedTab = tabsModel.activeTab
        XCTAssertEqual(tabsModel.tabs.count, 2)
        XCTAssertEqual(tabsModel.topLevelTabs.map(\.id), [linkedTab.id])

        // The group's entry keeps showing the worktree it was last on.
        tabsModel.addTab()
        let otherTabID = tabsModel.activeTabID
        XCTAssertEqual(tabsModel.topLevelTabs.map(\.id), [linkedTab.id, otherTabID])
        tabsModel.selectPrevious()
        XCTAssertEqual(tabsModel.activeTabID, linkedTab.id)

        tabsModel.moveTab(linkedTab.id, toIndex: 1)
        XCTAssertEqual(tabsModel.tabs.map(\.id), [otherTabID, mainTab.id, linkedTab.id])

        // Restored tabs group from the saved worktree list before loading.
        tabsModel.prepareForTermination()
        let restored = WorkspaceTabsModel(
            defaults: defaults,
            automaticallyActivatesInitialTab: false
        )
        XCTAssertEqual(restored.tabs.count, 3)
        XCTAssertEqual(restored.topLevelTabs.count, 2)

        tabsModel.close(linkedTab.id)
        XCTAssertEqual(tabsModel.tabs.map(\.id), [otherTabID])
    }

    func testClonesOfOneOriginShareAnEntryAndRestoreGroupedBeforeLoading() async throws {
        let first = try repository(origin: "git@github.com:me/x.git")
        let unrelated = try repository(origin: nil)
        let second = try repository(origin: "https://github.com/Me/x")
        defer { [first, unrelated, second].forEach { try? FileManager.default.removeItem(at: $0) } }
        let defaults = isolatedDefaults()
        let tabsModel = WorkspaceTabsModel(
            defaults: defaults,
            restoredRepositoryURLs: [first, unrelated, second]
        )
        let tabs = tabsModel.tabs
        XCTAssertEqual(tabsModel.topLevelTabs.count, 3)

        tabsModel.select(tabs[2].id)
        await waitForOrigin("github.com/me/x", in: tabs[2])
        tabsModel.select(tabs[0].id)
        await waitForOrigin("github.com/me/x", in: tabs[0])

        // The second clone moves next to the first once its origin is known.
        XCTAssertEqual(tabsModel.tabs.map(\.id), [tabs[1].id, tabs[0].id, tabs[2].id])
        XCTAssertEqual(tabsModel.topLevelTabs.count, 2)
        XCTAssertEqual(
            tabsModel.checkoutRegistry.checkouts(sameRepositoryAs: try XCTUnwrap(tabs[0].checkout)).count,
            2
        )

        tabsModel.prepareForTermination()
        let restored = WorkspaceTabsModel(
            defaults: defaults,
            automaticallyActivatesInitialTab: false
        )
        XCTAssertEqual(restored.tabs.map(\.id), tabsModel.tabs.map(\.id))
        XCTAssertEqual(restored.topLevelTabs.count, 2)

        tabsModel.close(tabs[0].id)
        XCTAssertEqual(tabsModel.tabs.map(\.id), [tabs[1].id])
    }

    func testOpeningACheckoutSelectsItsTabOrJoinsTheTabsOfTheSameOrigin() async throws {
        let first = try repository(origin: "git@github.com:me/x.git")
        let unrelated = try repository(origin: nil)
        let clone = try repository(origin: "git@github.com:me/x.git")
        defer { [first, unrelated, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        let defaults = isolatedDefaults()
        let tabsModel = WorkspaceTabsModel(
            defaults: defaults,
            restoredRepositoryURLs: [first, unrelated]
        )
        let firstTab = tabsModel.tabs[0]
        await waitForOrigin("github.com/me/x", in: firstTab)

        tabsModel.select(tabsModel.tabs[1].id)
        tabsModel.open(Checkout(host: nil, path: first.path))
        XCTAssertEqual(tabsModel.activeTabID, firstTab.id)
        XCTAssertEqual(tabsModel.tabs.count, 2)

        // The registry supplies the origin of a checkout it already knows.
        tabsModel.checkoutRegistry.register(
            Checkout(host: nil, path: clone.standardizedFileURL.path, origin: "github.com/me/x")
        )
        tabsModel.checkoutRegistry.register(Checkout(host: "zeta", path: "/srv/x", origin: "github.com/me/x"))
        tabsModel.checkoutRegistry.register(Checkout(host: "alpha", path: "/srv/x", origin: "github.com/me/x"))
        tabsModel.open(Checkout(host: nil, path: clone.standardizedFileURL.path))
        XCTAssertEqual(tabsModel.tabs.count, 3)
        XCTAssertEqual(tabsModel.tabs[1].repositoryURL?.standardizedFileURL.path, clone.standardizedFileURL.path)
        XCTAssertEqual(tabsModel.activeTabID, tabsModel.tabs[1].id)
        XCTAssertEqual(tabsModel.topLevelTabs.count, 2)

        // This Mac first, then hosts by name.
        XCTAssertEqual(
            tabsModel.checkouts(shownWith: firstTab).map(\.host),
            [nil, nil, "alpha", "zeta"]
        )

        // A dragged checkout lands at its index, and the order survives a
        // relaunch.
        tabsModel.moveCheckout("zeta:/srv/x", toIndex: 2, shownWith: firstTab)
        tabsModel.moveCheckout("alpha:/srv/x", toIndex: 0, shownWith: firstTab)
        XCTAssertEqual(
            tabsModel.checkouts(shownWith: firstTab).map(\.host),
            ["alpha", nil, nil, "zeta"]
        )
        XCTAssertEqual(
            WorkspaceTabsModel(defaults: defaults, restoreSavedTabs: false).checkoutOrder,
            tabsModel.checkoutOrder
        )

        // A tab connecting to its SSH checkout is named, loading, and in
        // its group before the host answers.
        let remote = Checkout(host: "kvist-test.invalid", path: "/srv/x", origin: "github.com/me/x")
        tabsModel.open(remote)
        let remoteTab = tabsModel.activeTab
        XCTAssertEqual(remoteTab.displayName, "x")
        XCTAssertTrue(remoteTab.isRepositoryLoadPending)
        XCTAssertEqual(remoteTab.checkout?.id, remote.id)
        XCTAssertTrue(remoteTab.shows(remote.worktree))
        XCTAssertEqual(tabsModel.topLevelTabs.count, 2)
        tabsModel.open(remote)
        XCTAssertEqual(tabsModel.tabs.count, 4)
    }

    func testWorktreePathDefaultsBesideTheMainWorktree() {
        XCTAssertEqual(
            RepositoryModel.worktreePath("", branch: "feat/x", mainPath: "/srv/repo", currentPath: "/srv/repo-y", isRemote: true),
            "/srv/repo-feat-x"
        )
        XCTAssertEqual(
            RepositoryModel.worktreePath("wt", branch: "x", mainPath: "/srv/repo", currentPath: "/srv/repo", isRemote: true),
            "/srv/repo/wt"
        )
        XCTAssertEqual(
            RepositoryModel.worktreePath("~/wt", branch: "x", mainPath: "/srv/repo", currentPath: "/srv/repo", isRemote: true),
            "/srv/repo/~/wt"
        )
    }

    func testAddingAWorktreeToACheckoutWithoutATabOpensIt() async throws {
        let base = try repository(origin: "git@github.com:me/x.git")
        let worktreePath = base.path + "-feature"
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(atPath: worktreePath)
        }
        _ = try GitClient(repositoryURL: base).run([
            "-c", "user.name=Kvist", "-c", "user.email=kvist@example.com",
            "commit", "--allow-empty", "-m", "Start"
        ])
        let tabsModel = WorkspaceTabsModel(defaults: isolatedDefaults(), restoreSavedTabs: false)

        await tabsModel.addWorktree(
            branch: "feature",
            path: "",
            in: Checkout(host: nil, path: base.path, origin: "github.com/me/x")
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath + "/.git"))
        XCTAssertEqual(tabsModel.activeTab.checkout?.path, worktreePath)
        XCTAssertEqual(tabsModel.activeTab.origin, "github.com/me/x")
        XCTAssertNotNil(tabsModel.checkoutRegistry.checkout(id: Checkout(host: nil, path: worktreePath).id))
    }

    func testCloseOthersKeepsOnlyTheGivenTab() {
        let tabsModel = WorkspaceTabsModel(
            defaults: isolatedDefaults(),
            restoreSavedTabs: false
        )
        tabsModel.addTab()
        tabsModel.addTab()
        let keptTabID = tabsModel.tabs[1].id

        tabsModel.closeOthers(keptTabID)

        XCTAssertEqual(tabsModel.tabs.map(\.id), [keptTabID])
        XCTAssertEqual(tabsModel.activeTabID, keptTabID)
    }

    func testRecentRepositoriesRestoreExistingPathsAndCanBeRemoved() throws {
        let defaults = isolatedDefaults()
        let existingURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: existingURL) }
        let missingPath = "/nonexistent/KvistTests-\(UUID().uuidString)"
        defaults.set(
            [existingURL.path, missingPath],
            forKey: "recentRepositoryPaths"
        )

        let tabsModel = WorkspaceTabsModel(
            defaults: defaults,
            restoreSavedTabs: false
        )

        XCTAssertEqual(
            tabsModel.recentRepositoryURLs.map(\.path),
            [existingURL.path]
        )

        tabsModel.removeRecentRepository(path: existingURL.path)

        XCTAssertTrue(tabsModel.recentRepositoryURLs.isEmpty)
        // A missing folder may be an unmounted volume, so it stays saved.
        XCTAssertEqual(
            defaults.stringArray(forKey: "recentRepositoryPaths"),
            [missingPath]
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "KvistTests.WorkspaceTabs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func waitForRepository(_ url: URL, in model: RepositoryModel) async {
        let deadline = Date().addingTimeInterval(3)
        while model.repositoryURL?.resolvingSymlinksInPath()
                != url.resolvingSymlinksInPath(),
              Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// A repository with one `origin` remote, or none.
    private func repository(origin: String?) throws -> URL {
        let url = try temporaryDirectory()
        try GitClient.initializeRepository(at: url, createGitIgnore: false)
        if let origin {
            _ = try GitClient(repositoryURL: url).run(["remote", "add", "origin", origin])
        }
        return url
    }

    private func waitForOrigin(_ origin: String, in tab: RepositoryTab) async {
        let deadline = Date().addingTimeInterval(5)
        while tab.origin != origin, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForRepositoryLoad(in tab: RepositoryTab) async {
        let deadline = Date().addingTimeInterval(3)
        while tab.isRepositoryLoadPending, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForEditor(in model: RepositoryModel) async {
        let deadline = Date().addingTimeInterval(3)
        while model.isDetailLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func waitForWatcher(in tabsModel: WorkspaceTabsModel) async {
        let deadline = Date().addingTimeInterval(3)
        while tabsModel.activeRepositoryWatcherCount != 1, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "KvistTabTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}

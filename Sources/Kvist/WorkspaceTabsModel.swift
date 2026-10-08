import AppKit
import Combine
import Foundation

@MainActor
final class RepositoryTab: ObservableObject, Identifiable {
    let id: UUID
    private var storedModel: RepositoryModel?
    fileprivate var repositoryPath: String?
    private var activationTask: Task<Void, Never>?
    private var activationGeneration = UUID()
    private var pendingRestorationState: RepositoryRestorationState?
    private var restorationSubscriptions: Set<AnyCancellable> = []
    fileprivate var restorationDidChange: (() -> Void)?
    fileprivate var modelDidInitialize: ((RepositoryModel) -> Void)?
    @Published private(set) var hasChanges = false
    @Published private(set) var isSSH = false
    @Published private(set) var isRepositoryLoadPending: Bool
    /// The tab's folder was not found when it was shown, for example on a
    /// drive that is not connected. The tab and any recovered draft stay
    /// until the folder returns or the user closes the tab.
    @Published private(set) var isFolderMissing = false
    /// Every worktree of the tab's repository once it has linked worktrees,
    /// and empty otherwise. Git lists the main worktree first. Saved with the
    /// workspace so restored tabs group before they load.
    @Published fileprivate(set) var worktrees: [GitWorktree] = []
    /// The normalized `origin` URL, which names the repository across
    /// machines. Saved with the workspace so restored tabs group before they
    /// load, and nil until Kvist reads the remotes.
    fileprivate(set) var origin: String?
    /// The SSH checkout this tab opens, until the model has loaded it and
    /// `repositoryPath` names the mirror. It names the tab and keeps the
    /// checkout bar on screen while Kvist connects.
    private var pendingRemote: Checkout?
    private var isOpeningRemote = false

    init(
        id: UUID = UUID(),
        repositoryURL: URL? = nil,
        restorationState: RepositoryRestorationState? = nil,
        worktrees: [GitWorktree] = [],
        origin: String? = nil,
        remote: Checkout? = nil
    ) {
        self.id = id
        repositoryPath = repositoryURL?.standardizedFileURL.path
        pendingRemote = remote
        pendingRestorationState = restorationState
        isRepositoryLoadPending = repositoryURL != nil || remote != nil
        self.worktrees = worktrees
        self.origin = origin
    }

    /// Tabs that show checkouts of one repository share this ID and one
    /// entry in the top row. Clones with the same origin group across
    /// machines. Without an origin, a repository's linked worktrees group
    /// through the main worktree's location.
    var groupID: String? {
        origin ?? worktrees.first.map { "\($0.sshHost ?? ""):\($0.path)" }
    }

    /// The folder this tab shows, on this Mac or on an SSH host. An SSH
    /// tab's own path is a local mirror, which this never returns.
    var checkout: Checkout? {
        guard let repositoryPath else {
            return pendingRemote.map { Checkout(host: $0.host, path: $0.path, origin: origin) }
        }
        let remote = storedModel?.sshRepository
            ?? SSHRepository.mirrored(at: URL(fileURLWithPath: repositoryPath, isDirectory: true))
        if let remote {
            return Checkout(host: remote.host, path: remote.path, origin: origin)
        }
        return Checkout(host: nil, path: repositoryPath, origin: origin)
    }

    var model: RepositoryModel {
        if let storedModel { return storedModel }
        let model = RepositoryModel(
            restoresLastRepository: false,
            persistsLastRepository: false,
            monitoringEnabled: false
        )
        storedModel = model
        observeRestorableState(model: model)
        modelDidInitialize?(model)
        return model
    }

    var loadedModel: RepositoryModel? {
        storedModel
    }

    var hasRecoveredDraft: Bool {
        pendingRestorationState?.editor?.isDirty == true
    }

    /// Asks before closing a tab with unsaved edits. A restored tab that was
    /// never shown keeps its recovered draft only in the restoration state.
    fileprivate func confirmDiscardChanges() -> Bool {
        // The model exists as soon as the tab is shown, but the recovered
        // draft stays pending until the repository finishes loading.
        guard let editor = pendingRestorationState?.editor, editor.isDirty else {
            return storedModel?.confirmDiscardRepositoryFileChanges() ?? true
        }
        let result = AppDialog.run(
            title: "Discard Recovered Changes?",
            message: "\(editor.title) has unsaved changes recovered from the last session. Open the tab to review or save them.",
            actions: [
                AppDialogAction(title: "Cancel", role: .cancel),
                AppDialogAction(title: "Discard Changes", role: .destructive)
            ]
        )
        return result.actionIndex == 1
    }

    func shows(_ worktree: GitWorktree) -> Bool {
        guard let repositoryPath else {
            return pendingRemote.map { $0.isSame(as: worktree) } ?? false
        }
        guard let sshHost = worktree.sshHost else {
            return repositoryPath == worktree.url.standardizedFileURL.path
        }
        // An SSH tab's path is its local mirror, so compare the remote
        // location recorded in the mirror.
        let remote = storedModel?.sshRepository
            ?? SSHRepository.mirrored(at: URL(fileURLWithPath: repositoryPath, isDirectory: true))
        return remote?.host == sshHost && remote?.path == worktree.path
    }

    var repositoryURL: URL? {
        storedModel?.repositoryURL ?? repositoryPath.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    var displayName: String {
        if let repositoryURL = storedModel?.repositoryURL {
            return repositoryURL.lastPathComponent
        }
        if let repositoryPath {
            return URL(fileURLWithPath: repositoryPath).lastPathComponent
        }
        return pendingRemote?.name ?? "New"
    }

    fileprivate func activate() {
        let model = model
        guard model.repositoryInitializationURL == nil else {
            isRepositoryLoadPending = false
            return
        }
        guard !model.isBusy else { return }
        if model.repositoryURL == nil, repositoryPath == nil,
           let remote = pendingRemote, let host = remote.host {
            // Switching away leaves the connection running, as for a clone,
            // so this task is not the cancellable activation task.
            guard !isOpeningRemote else { return }
            isOpeningRemote = true
            isRepositoryLoadPending = true
            Task { [weak self, weak model] in
                await model?.openSSHRepository(host: host, path: remote.path)
                self?.isOpeningRemote = false
                self?.isRepositoryLoadPending = false
            }
            return
        }
        let repositoryURL: URL?
        if let deferredRepositoryOpenURL = model.deferredRepositoryOpenURL {
            repositoryURL = deferredRepositoryOpenURL
        } else if model.repositoryURL == nil {
            repositoryURL = repositoryPath.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
        } else {
            repositoryURL = nil
        }
        guard let repositoryURL else {
            isRepositoryLoadPending = false
            return
        }
        isFolderMissing = !FileManager.default.fileExists(atPath: repositoryURL.path)
        guard !isFolderMissing else {
            isRepositoryLoadPending = false
            return
        }
        isRepositoryLoadPending = true
        let generation = UUID()
        activationGeneration = generation
        let opensAsPlainFolder = pendingRestorationState?.opensAsPlainFolder ?? false
        activationTask = Task { [weak self, weak model] in
            await model?.openRepository(
                repositoryURL,
                asPlainFolder: opensAsPlainFolder
            )
            guard let self,
                  self.activationGeneration == generation else { return }
            if let state = self.pendingRestorationState {
                self.pendingRestorationState = nil
                await model?.restore(from: state)
            }
            self.activationTask = nil
            self.isRepositoryLoadPending = false
            self.restorationDidChange?()
        }
    }

    /// Closing a tab also stops a running clone or SSH connection. Switching
    /// away leaves them running so they finish in the background.
    fileprivate func deactivate(isClosing: Bool = false) {
        guard let model = storedModel else { return }
        activationGeneration = UUID()
        activationTask?.cancel()
        activationTask = nil
        model.cancelRepositoryOpen(includingCloneAndConnection: isClosing)
        model.setMonitoringEnabled(false)
        isRepositoryLoadPending = model.repositoryURL == nil
            && model.repositoryInitializationURL == nil
            && (repositoryPath != nil || isOpeningRemote)
    }

    fileprivate var restorationState: RepositoryRestorationState {
        pendingRestorationState ?? storedModel?.makeRestorationState()
            ?? RepositoryRestorationState()
    }

    private func observeRestorableState(model: RepositoryModel) {
        model.restorationStateDidChange = { [weak self] in
            guard self?.pendingRestorationState == nil else { return }
            self?.restorationDidChange?()
        }
        let publishers: [AnyPublisher<Void, Never>] = [
            model.$workspaceMode.map { _ in () }.eraseToAnyPublisher(),
            model.$expandedFileDirectories.map { _ in () }.eraseToAnyPublisher(),
            model.$expandedCommitHashes.map { _ in () }.eraseToAnyPublisher(),
            model.$graphScope.map { _ in () }.eraseToAnyPublisher(),
            model.$selectedRepositoryFilePath.map { _ in () }.eraseToAnyPublisher(),
            model.$isDiffPanelPresented.map { _ in () }.eraseToAnyPublisher(),
            model.$detailKind.map { _ in () }.eraseToAnyPublisher(),
            model.$repositoryFileDirty.map { _ in () }.eraseToAnyPublisher(),
            model.commitMessageState.$text.map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(publishers)
            .dropFirst()
            .sink { [weak self] _ in
                guard self?.pendingRestorationState == nil else { return }
                self?.restorationDidChange?()
            }
            .store(in: &restorationSubscriptions)
        model.$staged.combineLatest(model.$unstaged)
            .map { !$0.isEmpty || !$1.isEmpty }
            .removeDuplicates()
            .sink { [weak self] in self?.hasChanges = $0 }
            .store(in: &restorationSubscriptions)
        model.$sshRepository
            .map { $0 != nil }
            .removeDuplicates()
            .assign(to: &$isSSH)
    }
}
private struct RestoredRepositoryTab: Codable {
    let id: UUID
    let repositoryPath: String?
    let state: RepositoryRestorationState
    let worktrees: [GitWorktree]?
    /// Added after the first release of this format, so older saved
    /// workspaces decode without it.
    let origin: String?
}

private struct RestoredWorkspace: Codable {
    let activeTabID: UUID
    let tabs: [RestoredRepositoryTab]
}

@MainActor
final class WorkspaceTabsModel: ObservableObject {
    @Published private(set) var tabs: [RepositoryTab] = []
    @Published private(set) var activeTabID: UUID {
        didSet { activeTabDidChange(from: oldValue) }
    }
    @Published private(set) var recentRepositoryPaths: [String] = []
    /// Every checkout of every repository, across this Mac and SSH hosts.
    let checkoutRegistry: CheckoutRegistry
    /// SSH hosts and the repositories scans found on every machine.
    let hostsModel: SSHHostsModel

    private let defaults: UserDefaults
    private let persistenceEnabled: Bool
    private let monitoringActivationDelayMilliseconds: Int
    private var hasActivatedInitialTab = false
    private let openRepositoriesKey = "openRepositoryPaths"
    private let activeRepositoryKey = "activeRepositoryPath"
    private let legacyRepositoryKey = "lastRepositoryPath"
    private let recentRepositoriesKey = "recentRepositoryPaths"
    private let restoredWorkspaceKey = "restoredWorkspaceV2"
    private let recentRepositoriesLimit = 7
    private var repositorySubscriptions: [UUID: [AnyCancellable]] = [:]
    /// The tab each worktree group showed last, so its top-row entry returns
    /// to that worktree.
    private var lastActiveTabIDByGroup: [String: UUID] = [:]
    private var activeModelSubscription: AnyCancellable?
    private var persistenceTask: Task<Void, Never>?
    private var monitoringActivationWorkItem: DispatchWorkItem?

    init(
        defaults: UserDefaults = .standard,
        restoreSavedTabs: Bool = true,
        initialRepositoryURL: URL? = nil,
        restoredRepositoryURLs: [URL]? = nil,
        persistenceEnabled: Bool = true,
        automaticallyActivatesInitialTab: Bool = true,
        monitoringActivationDelayMilliseconds: Int = 100
    ) {
        self.defaults = defaults
        self.persistenceEnabled = persistenceEnabled
        checkoutRegistry = CheckoutRegistry(
            defaults: defaults,
            persistenceEnabled: persistenceEnabled
        )
        hostsModel = SSHHostsModel(defaults: defaults, persistenceEnabled: persistenceEnabled)
        self.monitoringActivationDelayMilliseconds = max(
            0,
            monitoringActivationDelayMilliseconds
        )
        // Keep entries whose folder is missing, such as on an unmounted
        // volume. recentRepositoryURLs hides them until the folder returns.
        recentRepositoryPaths = defaults.stringArray(forKey: recentRepositoriesKey) ?? []

        let restoredWorkspace = restoreSavedTabs
            ? defaults.data(forKey: restoredWorkspaceKey).flatMap {
                try? JSONDecoder().decode(RestoredWorkspace.self, from: $0)
            }
            : nil

        let savedPaths: [String]
        if restoreSavedTabs, restoredWorkspace == nil {
            let currentPaths = defaults.stringArray(forKey: openRepositoriesKey) ?? []
            if currentPaths.isEmpty,
               let legacyPath = defaults.string(forKey: legacyRepositoryKey) {
                savedPaths = [legacyPath]
            } else {
                savedPaths = currentPaths
            }
        } else {
            savedPaths = []
        }

        var seen = Set<String>()
        // Tabs whose folder is missing stay; the tab shows that the folder
        // is not available instead of silently dropping it and its draft.
        let repositoryURLs = savedPaths.compactMap { path -> URL? in
            let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seen.insert(standardizedPath).inserted else { return nil }
            return URL(fileURLWithPath: standardizedPath, isDirectory: true)
        }

        let detailedTabs = restoredWorkspace?.tabs.compactMap { saved -> RepositoryTab? in
            guard let path = saved.repositoryPath else {
                return RepositoryTab(id: saved.id, restorationState: saved.state)
            }
            let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seen.insert(standardizedPath).inserted else { return nil }
            return RepositoryTab(
                id: saved.id,
                repositoryURL: URL(fileURLWithPath: standardizedPath, isDirectory: true),
                restorationState: saved.state,
                worktrees: saved.worktrees ?? [],
                origin: saved.origin
            )
        } ?? []
        let restoredTabs: [RepositoryTab]
        if let restoredRepositoryURLs {
            restoredTabs = restoredRepositoryURLs.map { RepositoryTab(repositoryURL: $0) }
        } else if let initialRepositoryURL {
            restoredTabs = [RepositoryTab(repositoryURL: initialRepositoryURL)]
        } else {
            restoredTabs = detailedTabs.isEmpty
                ? repositoryURLs.map { RepositoryTab(repositoryURL: $0) }
                : detailedTabs
        }
        let initialTabs = restoredTabs.isEmpty ? [RepositoryTab()] : restoredTabs
        tabs = initialTabs

        let preferredPath = defaults.string(forKey: activeRepositoryKey)
        let preferredIndex = restoredWorkspace.flatMap { workspace in
            initialTabs.firstIndex { $0.id == workspace.activeTabID }
        } ?? preferredPath.flatMap { path in
            initialTabs.firstIndex {
                $0.repositoryPath
                    == URL(fileURLWithPath: path).standardizedFileURL.path
            }
        } ?? 0
        activeTabID = initialTabs[preferredIndex].id

        initialTabs.forEach(observeRepository)
        // Avoid materializing the active RepositoryModel until a caller has
        // explicitly activated the lazily restored workspace.
        if automaticallyActivatesInitialTab {
            activateInitialTab()
        }
    }

    deinit {
        persistenceTask?.cancel()
        monitoringActivationWorkItem?.cancel()
    }

    private func activeTabDidChange(from oldTabID: UUID) {
        monitoringActivationWorkItem?.cancel()
        if let oldTab = tabs.first(where: { $0.id == oldTabID }) {
            if let group = oldTab.groupID {
                lastActiveTabIDByGroup[group] = oldTab.id
            }
            oldTab.deactivate()
        }
        activate(activeTab)
        forwardActiveModelChanges()
    }

    func activateInitialTab() {
        guard !hasActivatedInitialTab else { return }
        hasActivatedInitialTab = true
        forwardActiveModelChanges()
        activate(activeTab)
    }

    private func activate(_ tab: RepositoryTab) {
        tab.activate()
        let tabID = tab.id
        let workItem = DispatchWorkItem { [weak self, weak tab] in
            guard let self,
                  self.activeTabID == tabID else { return }
            tab?.model.setMonitoringEnabled(true)
            self.monitoringActivationWorkItem = nil
        }
        monitoringActivationWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(monitoringActivationDelayMilliseconds),
            execute: workItem
        )
    }

    /// Menu-bar commands read state from the active tab's repository model, so
    /// command-relevant changes republish through this object for validation.
    /// Keeping editor text out of this stream prevents every keystroke from
    /// invalidating the complete window hierarchy.
    private func forwardActiveModelChanges() {
        let model = activeModel
        let commandState: [AnyPublisher<Void, Never>] = [
            model.$repositoryURL.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$workspaceMode.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$selectedRepositoryFilePath.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$detailKind.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$repositoryFileDirty.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$isSavingRepositoryFile.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$isDiffPanelPresented.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$isBusy.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$isGeneratingCommitMessage.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$pendingChangePaths.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$staged.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$unstaged.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$hasUpstream.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$branch.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$headHash.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]
        activeModelSubscription = Publishers.MergeMany(commandState)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    var activeTab: RepositoryTab {
        tabs.first(where: { $0.id == activeTabID }) ?? tabs[0]
    }

    var activeModel: RepositoryModel {
        activeTab.model
    }

    var activeRepositoryWatcherCount: Int {
        tabs.count { $0.loadedModel?.hasActiveRepositoryWatcher == true }
    }

    var outstandingRepositoryTaskCount: Int {
        tabs.count { $0.loadedModel?.hasOutstandingRepositoryTasks == true }
    }

    /// Opens the active tab again if its folder was missing, such as after
    /// the user connects the drive it lives on.
    func retryMissingActiveTab() {
        guard activeTab.isFolderMissing else { return }
        activeTab.activate()
    }

    func addTab() {
        let tab = RepositoryTab()
        tabs.append(tab)
        observeRepository(tab)
        activeTabID = tab.id
        persistTabs()
    }

    /// The top row's entries: one per repository. The tabs of one
    /// repository's worktrees share an entry, shown by the active tab or the
    /// one the group showed last.
    var topLevelTabs: [RepositoryTab] {
        var seenGroups = Set<String>()
        return tabs.compactMap { tab in
            guard let group = tab.groupID else { return tab }
            guard seenGroups.insert(group).inserted else { return nil }
            return representative(of: tab)
        }
    }

    /// The tabs that share the tab's top-row entry, in tab order.
    func group(of tab: RepositoryTab) -> [RepositoryTab] {
        guard let group = tab.groupID else { return [tab] }
        return tabs.filter { $0.groupID == group }
    }

    private func representative(of tab: RepositoryTab) -> RepositoryTab {
        let members = group(of: tab)
        let lastActiveID = tab.groupID.flatMap { lastActiveTabIDByGroup[$0] }
        return members.first { $0.id == activeTabID }
            ?? members.first { $0.id == lastActiveID }
            ?? members.first
            ?? tab
    }

    /// Selects the tab that shows the worktree, or opens it in a new tab
    /// after the active one so each worktree keeps its own drafts and panels.
    /// The new tab joins the active tab's group in the top row.
    func switchToWorktree(_ worktree: GitWorktree) {
        openTab(for: worktree, origin: activeTab.origin, after: group(of: activeTab))
    }

    /// Selects the tab that shows the checkout, or opens it in a new tab
    /// after the tabs of the same repository. A checkout of a repository
    /// with no open tab goes to the end, unless it is a worktree of the
    /// active repository.
    func open(_ checkout: Checkout) {
        let origin = checkout.origin ?? checkoutRegistry.checkout(id: checkout.id)?.origin
        var anchor = origin.map { origin in tabs.filter { $0.origin == origin } } ?? []
        if anchor.isEmpty, activeTab.worktrees.contains(where: checkout.isSame(as:)) {
            anchor = group(of: activeTab)
        }
        openTab(for: checkout.worktree, origin: origin, after: anchor)
    }

    private func openTab(for worktree: GitWorktree, origin: String?, after anchor: [RepositoryTab]) {
        if let existingTab = tabs.first(where: { $0.shows(worktree) }) {
            select(existingTab.id)
            return
        }
        // Another machine's tab never takes this tab's worktree list, whose
        // paths mean nothing there.
        let sharesWorktrees = activeTab.worktrees.contains {
            $0.sshHost == worktree.sshHost && $0.path == worktree.path
        }
        let tab = RepositoryTab(
            repositoryURL: worktree.sshHost == nil ? worktree.url : nil,
            worktrees: sharesWorktrees ? activeTab.worktrees : [],
            origin: origin,
            // Activating the tab connects to the host.
            remote: worktree.sshHost == nil ? nil : Checkout(worktree: worktree)
        )
        let index = tabs.lastIndex { tab in anchor.contains { $0 === tab } } ?? tabs.count - 1
        tabs.insert(tab, at: index + 1)
        observeRepository(tab)
        activeTabID = tab.id
        persistTabs()
    }

    /// The checkouts to list under the tab row for the tab's repository, this
    /// Mac first, then SSH hosts by name. Within a machine the main worktree
    /// comes first. The list joins the registry's clones of the repository
    /// with the worktrees that open tabs know about.
    func checkouts(shownWith tab: RepositoryTab) -> [Checkout] {
        let members = group(of: tab)
        var mainIDs = Set<Checkout.ID>()
        var found: [Checkout] = []
        if let own = tab.checkout {
            found += checkoutRegistry.checkouts(sameRepositoryAs: own)
        }
        for member in members {
            if let main = member.worktrees.first {
                mainIDs.insert(Checkout(worktree: main).id)
            }
            found += member.worktrees.map { Checkout(worktree: $0, origin: member.origin) }
            found += member.checkout.map { [$0] } ?? []
        }
        var seen = Set<Checkout.ID>()
        let unique = found.filter { seen.insert($0.id).inserted }
        return unique.enumerated().sorted { first, second in
            func key(_ item: (offset: Int, element: Checkout)) -> (Int, String, Int, Int) {
                (
                    item.element.host == nil ? 0 : 1,
                    item.element.host ?? "",
                    mainIDs.contains(item.element.id) ? 0 : 1,
                    item.offset
                )
            }
            return key(first) < key(second)
        }.map(\.element)
    }

    /// Creates a worktree of the checkout's repository on the checkout's
    /// machine and opens it. An open tab for the checkout does the work, so
    /// its lists update. Otherwise Git runs in the checkout directly.
    func addWorktree(branch: String, path: String, in base: Checkout) async {
        if let model = tabs.first(where: { $0.shows(base.worktree) })?.loadedModel,
           model.repositoryURL != nil {
            if let worktree = await model.addWorktree(branch: branch, path: path) {
                open(Checkout(worktree: worktree, origin: base.origin))
            }
            return
        }
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = RepositoryModel.worktreePath(
            path,
            branch: branch,
            mainPath: base.path,
            currentPath: base.path,
            isRemote: base.host != nil
        )
        do {
            let remote = try base.host.map { try SSHRepository(host: $0, path: base.path) }
            let client = GitClient(
                repositoryURL: URL(fileURLWithPath: base.path, isDirectory: true),
                sshRepository: remote
            )
            try await Task.detached(priority: .userInitiated) {
                try client.addWorktree(path: path, branch: branch)
            }.value
        } catch {
            let output = (error as? GitCommandError)?.output ?? error.localizedDescription
            _ = AppDialog.run(
                title: "Could Not Create Worktree",
                message: output.trimmingCharacters(in: .whitespacesAndNewlines),
                actions: [AppDialogAction(title: "OK", role: .primary)]
            )
            return
        }
        let checkout = Checkout(host: base.host, path: path, origin: base.origin)
        checkoutRegistry.register(checkout)
        open(checkout)
    }

    /// Opens the Nth checkout in the active tab's checkout bar, counting from 1.
    func openCheckout(at position: Int) {
        let tab = activeTab
        guard let model = tab.loadedModel,
              model.repositoryURL != nil,
              !model.isPlainFolder else { return }
        let checkouts = checkouts(shownWith: tab)
        guard checkouts.indices.contains(position - 1) else { return }
        open(checkouts[position - 1])
    }

    /// Whether a tab shows the checkout.
    func isOpen(_ checkout: Checkout) -> Bool {
        tabs.contains { $0.shows(checkout.worktree) }
    }

    /// Removes a worktree of the active repository and closes its tabs,
    /// moving to another worktree first if the active tab shows it.
    func removeWorktree(_ worktree: GitWorktree) {
        let model = activeModel
        let affectedTabs = tabs.filter { $0.shows(worktree) }
        guard affectedTabs.allSatisfy({ $0.confirmDiscardChanges() }) else { return }
        Task {
            guard await model.removeWorktree(worktree) else { return }
            if affectedTabs.contains(where: { $0.id == activeTabID }),
               let remaining = model.worktrees.first(where: { $0.path != worktree.path }) {
                switchToWorktree(remaining)
            }
            closeTabs(affectedTabs)
        }
    }

    func select(_ tabID: UUID) {
        guard tabID != activeTabID,
              tabs.contains(where: { $0.id == tabID }) else { return }
        activeTabID = tabID
        persistTabs()
    }

    func selectNext() {
        selectAdjacentTab(offset: 1)
    }

    func selectPrevious() {
        selectAdjacentTab(offset: -1)
    }

    private func selectAdjacentTab(offset: Int) {
        let entries = topLevelTabs
        guard entries.count > 1,
              let index = entries.firstIndex(where: { $0.id == activeTabID }) else {
            return
        }
        let next = (index + offset + entries.count) % entries.count
        select(entries[next].id)
    }

    /// Moves a top-row entry, with all of its worktree tabs, to `targetIndex`
    /// in the top row.
    func moveTab(_ tabID: UUID, toIndex targetIndex: Int) {
        var entries = topLevelTabs
        guard let index = entries.firstIndex(where: { $0.id == tabID }) else { return }
        let destination = min(max(targetIndex, 0), entries.count - 1)
        guard destination != index else { return }
        entries.insert(entries.remove(at: index), at: destination)
        tabs = entries.flatMap(group(of:))
        persistTabs()
    }

    /// Closes the tab together with the tabs of its repository's other
    /// worktrees, since they share one entry in the top row.
    func close(_ tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        let closedTabs = group(of: tab)
        guard closedTabs.allSatisfy({ $0.confirmDiscardChanges() }) else { return }
        closeTabs(closedTabs)
    }

    /// Closes only this tab, leaving the repository's other checkouts open.
    func closeTab(_ tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              tab.confirmDiscardChanges() else { return }
        closeTabs([tab])
    }

    private func closeTabs(_ closedTabs: [RepositoryTab]) {
        let closedIDs = Set(closedTabs.map(\.id))
        guard let index = tabs.firstIndex(where: { closedIDs.contains($0.id) }) else { return }
        for tab in closedTabs {
            tab.deactivate(isClosing: true)
            repositorySubscriptions[tab.id] = nil
        }
        tabs.removeAll { closedIDs.contains($0.id) }
        removeSSHDownloads(of: closedTabs)

        if tabs.isEmpty {
            let replacement = RepositoryTab()
            tabs = [replacement]
            observeRepository(replacement)
            activeTabID = replacement.id
        } else if closedIDs.contains(activeTabID) {
            activeTabID = representative(of: tabs[min(index, tabs.count - 1)]).id
        }

        persistTabs()
    }

    func closeOthers(_ tabID: UUID) {
        guard let keptTab = tabs.first(where: { $0.id == tabID }) else { return }
        let keptTabs = group(of: keptTab)
        let closedTabs = tabs.filter { tab in !keptTabs.contains { $0 === tab } }
        guard closedTabs.allSatisfy({ $0.confirmDiscardChanges() }) else { return }
        for tab in closedTabs {
            tab.deactivate(isClosing: true)
            repositorySubscriptions[tab.id] = nil
        }
        tabs = keptTabs
        removeSSHDownloads(of: closedTabs)
        if !keptTabs.contains(where: { $0.id == activeTabID }) {
            activeTabID = keptTab.id
        }
        persistTabs()
    }

    var isShowingOnlyEmptyTab: Bool {
        tabs.count == 1 && activeTab.repositoryPath == nil
    }

    /// ⌘W closes the active repository tab, or the window once only the
    /// empty welcome tab is left, as in other tabbed Mac apps.
    func closeActiveTabOrWindow() {
        if isShowingOnlyEmptyTab {
            NSApp.keyWindow?.performClose(nil)
        } else {
            close(activeTabID)
        }
    }

    var hasRunningOperations: Bool {
        tabs.contains { tab in
            guard let model = tab.loadedModel else { return false }
            return model.isBusy
                || model.isSavingRepositoryFile
                || model.isGeneratingCommitMessage
                || model.hasPendingChangeOperations
        }
    }

    /// Saves the workspace for restoration, or asks about unsaved files when
    /// restoration is off. Returns false when the user cancels quitting.
    func prepareToQuit() -> Bool {
        if defaults.object(forKey: "restoreWorkspaceOnLaunch") == nil
            || defaults.bool(forKey: "restoreWorkspaceOnLaunch") {
            prepareForTermination()
            return true
        }
        return confirmDiscardAllRepositoryFileChanges()
    }

    /// A closed SSH tab's downloaded files are a cache nothing else needs,
    /// unless another tab shows the same remote location.
    private func removeSSHDownloads(of closedTabs: [RepositoryTab]) {
        let openPaths = Set(tabs.compactMap(\.repositoryPath))
        for path in closedTabs.compactMap(\.repositoryPath) where !openPaths.contains(path) {
            SSHMirrorStore.removeDownloads(at: URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    /// Clears mirrors that no open tab uses. Run once at launch.
    func removeUnusedSSHMirrors() {
        let openPaths = Set(tabs.compactMap(\.repositoryPath))
        let recentPaths = Set(recentRepositoryPaths)
        DispatchQueue.global(qos: .utility).async {
            SSHMirrorStore.removeUnused(keepingOpen: openPaths, recent: recentPaths)
        }
    }

    var hasUnsavedRepositoryFileChanges: Bool {
        tabs.contains { $0.loadedModel?.hasUnsavedRepositoryFileChanges == true }
    }

    func confirmDiscardAllRepositoryFileChanges() -> Bool {
        tabs.allSatisfy { $0.confirmDiscardChanges() }
    }

    var recentRepositoryURLs: [URL] {
        recentRepositoryPaths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func removeRecentRepository(path: String) {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        recentRepositoryPaths.removeAll { $0 == standardizedPath }
        if persistenceEnabled {
            defaults.set(recentRepositoryPaths, forKey: recentRepositoriesKey)
        }
    }

    private func recordRecentRepository(path: String) {
        var paths = recentRepositoryPaths.filter { $0 != path }
        paths.insert(path, at: 0)
        recentRepositoryPaths = Array(paths.prefix(recentRepositoriesLimit))
        if persistenceEnabled {
            defaults.set(recentRepositoryPaths, forKey: recentRepositoriesKey)
        }
    }

    private func observeRepository(_ tab: RepositoryTab) {
        tab.restorationDidChange = { [weak self] in
            self?.scheduleWorkspacePersistence()
        }
        tab.modelDidInitialize = { [weak self, weak tab] model in
            guard let self, let tab else { return }
            self.observeRepositoryModel(model, for: tab)
        }
        if let model = tab.loadedModel {
            observeRepositoryModel(model, for: tab)
        }
    }

    private func observeRepositoryModel(_ model: RepositoryModel, for tab: RepositoryTab) {
        model.switchToWorktree = { [weak self] in self?.switchToWorktree($0) }
        repositorySubscriptions[tab.id] = [
            model.$repositoryURL
                .dropFirst()
                .sink { [weak self, weak tab] repositoryURL in
                    let path = repositoryURL?.standardizedFileURL.path
                    tab?.repositoryPath = path
                    tab?.objectWillChange.send()
                    if let path {
                        self?.recordRecentRepository(path: path)
                    }
                    self?.persistTabs()
                },
            // Read the worktrees only once a repository has loaded, so a
            // restored tab keeps its saved list until then. Watching the URL
            // too catches a load that finds no linked worktrees, which leaves
            // the model's empty list unchanged.
            model.$repositoryURL.combineLatest(model.$worktrees)
                .sink { [weak self, weak tab] repositoryURL, worktrees in
                    guard let self, let tab, repositoryURL != nil else { return }
                    let grouped = worktrees.count > 1 ? worktrees : []
                    guard tab.worktrees != grouped else { return }
                    // The top row is drawn from this object, not the tab.
                    self.objectWillChange.send()
                    tab.worktrees = grouped
                    self.persistTabs()
                },
            // Registers the tab's checkouts and reads its origin. The
            // publishers fire before the model stores a value, and a load
            // sets the URL before the SSH location and remotes, so wait for
            // the turn to end and read the settled model.
            Publishers.MergeMany(
                model.$repositoryURL.map { _ in () }.eraseToAnyPublisher(),
                model.$sshRepository.map { _ in () }.eraseToAnyPublisher(),
                model.$remotes.map { _ in () }.eraseToAnyPublisher(),
                model.$worktrees.map { _ in () }.eraseToAnyPublisher()
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak tab, weak model] in
                guard let self, let tab, let model else { return }
                self.registerCheckouts(of: model, for: tab)
            }
        ]
    }

    /// The `origin` remote's identity, or the first remote's when the
    /// repository has no `origin`.
    private static func origin(of remotes: [GitRemote]) -> String? {
        let remote = remotes.first { $0.name == "origin" } ?? remotes.first
        return remote.flatMap { Checkout.normalizedOrigin($0.fetchURL) }
    }

    private func registerCheckouts(of model: RepositoryModel, for tab: RepositoryTab) {
        guard model.repositoryURL != nil, !model.isPlainFolder else { return }
        let origin = Self.origin(of: model.remotes)
        // Git lists the main worktree first, so register in that order.
        let listed = model.worktrees.map { Checkout(worktree: $0, origin: origin) }
        let own: Checkout?
        if let remote = model.sshRepository {
            own = Checkout(host: remote.host, path: remote.path, origin: origin)
        } else {
            own = model.repositoryURL.map {
                Checkout(host: nil, path: $0.standardizedFileURL.path, origin: origin)
            }
        }
        (listed + [own].compactMap { $0 }).forEach(checkoutRegistry.register)
        guard tab.origin != origin else { return }
        // The top row is drawn from this object, not the tab.
        objectWillChange.send()
        tab.origin = origin
        gatherGroup(of: tab)
        persistTabs()
    }

    /// Moves the tab next to the other tabs of its group, if it is not
    /// already, as when a freshly opened tab learns its origin.
    private func gatherGroup(of tab: RepositoryTab) {
        let members = group(of: tab)
        guard members.count > 1 else { return }
        let indices = members.compactMap { member in tabs.firstIndex { $0 === member } }
        guard let first = indices.min(), let last = indices.max(),
              last - first + 1 != members.count else { return }
        // Keep the others where they are. The tab lands on the side it was
        // already on, so it moves no further than it needs to.
        let wasBefore = tabs.firstIndex { $0 === tab } == first
        var reordered = tabs.filter { $0 !== tab }
        let otherIndices = reordered.indices.filter { index in
            members.contains { $0 === reordered[index] }
        }
        guard let firstOther = otherIndices.first, let lastOther = otherIndices.last else { return }
        reordered.insert(tab, at: wasBefore ? firstOther : lastOther + 1)
        tabs = reordered
    }

    private func persistTabs() {
        guard persistenceEnabled else { return }
        let paths = tabs.compactMap(\.repositoryPath)
        defaults.set(paths, forKey: openRepositoriesKey)

        if let activePath = activeTab.repositoryPath {
            defaults.set(activePath, forKey: activeRepositoryKey)
            defaults.set(activePath, forKey: legacyRepositoryKey)
        } else {
            defaults.removeObject(forKey: activeRepositoryKey)
            if paths.isEmpty {
                defaults.removeObject(forKey: legacyRepositoryKey)
            }
        }
        scheduleWorkspacePersistence()
    }

    func prepareForTermination() {
        guard persistenceEnabled else { return }
        persistenceTask?.cancel()
        persistWorkspaceImmediately()
    }

    private func scheduleWorkspacePersistence() {
        guard persistenceEnabled else { return }
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.persistWorkspaceImmediately()
        }
    }

    private func persistWorkspaceImmediately() {
        guard persistenceEnabled else { return }
        let savedTabs = tabs.map {
            RestoredRepositoryTab(
                id: $0.id,
                repositoryPath: $0.repositoryPath,
                state: $0.restorationState,
                worktrees: $0.worktrees,
                origin: $0.origin
            )
        }
        let workspace = RestoredWorkspace(
            activeTabID: activeTabID,
            tabs: savedTabs
        )
        if let data = try? JSONEncoder().encode(workspace) {
            defaults.set(data, forKey: restoredWorkspaceKey)
        }
    }
}

extension Checkout {
    /// A local worktree's path is standardized, so `/private/var/x` from
    /// `git worktree list` and `/var/x` from a tab name the same checkout.
    init(worktree: GitWorktree, origin: String? = nil) {
        self.init(
            host: worktree.sshHost,
            path: worktree.sshHost == nil ? worktree.url.standardizedFileURL.path : worktree.path,
            origin: origin
        )
    }

    func isSame(as worktree: GitWorktree) -> Bool {
        id == Checkout(worktree: worktree).id
    }
}

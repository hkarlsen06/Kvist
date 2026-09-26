import AppKit
import QuartzCore
import SwiftUI

@main
struct KvistApp: App {
    @NSApplicationDelegateAdaptor(KvistAppDelegate.self) private var appDelegate
    @StateObject private var tabsModel: WorkspaceTabsModel
    @StateObject private var themePreferences: ThemePreferences
    @State private var hasPresentedInitialFrame = false

    init() {
        // Writing to a child process whose stdin has closed, such as an `ssh` that
        // failed to connect or a helper that exited early, otherwise kills the app
        // with SIGPIPE, before any Swift error can be thrown. Ignoring it turns
        // those writes into an EPIPE the caller can handle.
        signal(SIGPIPE, SIG_IGN)
        let benchmark = KvistPerformanceInstrumentation.configuration
        if benchmark != nil {
            KvistRuntimeMetrics.reset()
        }
        let defaults: UserDefaults
        if benchmark != nil,
           let benchmarkDefaults = UserDefaults(
               suiteName: "com.hjalmarkarlsen.Kvist.PerformanceBenchmark"
           ) {
            benchmarkDefaults.removePersistentDomain(
                forName: "com.hjalmarkarlsen.Kvist.PerformanceBenchmark"
            )
            defaults = benchmarkDefaults
        } else {
            defaults = .standard
        }
        // bool(forKey:) also reads "NO" passed as a launch argument.
        let restoresWorkspace = defaults.object(forKey: "restoreWorkspaceOnLaunch") == nil
            || defaults.bool(forKey: "restoreWorkspaceOnLaunch")
        let tabsModel = WorkspaceTabsModel(
            restoreSavedTabs: benchmark == nil && restoresWorkspace,
            initialRepositoryURL: benchmark?.opensRepository == true
                ? benchmark?.repositoryURL
                : nil,
            restoredRepositoryURLs: benchmark?.mode == .tabs
                ? benchmark?.tabRepositoryURLs
                : nil,
            persistenceEnabled: benchmark == nil,
            automaticallyActivatesInitialTab: false,
            monitoringActivationDelayMilliseconds: benchmark?.mode == .tabs
                ? 2_000
                : 100
        )
        if benchmark == nil {
            tabsModel.removeUnusedSSHMirrors()
        }
        _tabsModel = StateObject(wrappedValue: tabsModel)
        _themePreferences = StateObject(
            wrappedValue: ThemePreferences(defaults: defaults)
        )
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasPresentedInitialFrame {
                    ContentView()
                } else {
                    InitialWindowContent()
                }
            }
                .id(themePreferences.appearanceStamp)
                .environmentObject(tabsModel)
                .environmentObject(themePreferences)
                .onAppear {
                    appDelegate.tabsModel = tabsModel
                    AppUpdater.workspace = tabsModel
                }
                .preferredColorScheme(themePreferences.preferredColorScheme)
                .tint(AppTheme.actionBlue)
                .frame(
                    minWidth: 420,
                    maxWidth: .infinity,
                    minHeight: 588,
                    maxHeight: .infinity
                )
                .overlay(alignment: .topLeading) {
                    WindowConfigurator {
                        guard !hasPresentedInitialFrame else { return }
                        KvistPerformanceInstrumentation.recordInitialFrame()
                        KvistPerformanceInstrumentation.recordTabsBeforeInitialSelection(
                            tabsModel
                        )
                        DispatchQueue.main.async {
                            guard !hasPresentedInitialFrame else { return }
                            hasPresentedInitialFrame = true
                            tabsModel.activateInitialTab()
                            KvistPerformanceInstrumentation.runTabMeasurementsIfRequested(
                                tabsModel: tabsModel
                            )
                            KvistInteractionPerformanceInstrumentation.runIfRequested(
                                model: tabsModel.activeModel
                            )
                            KvistHistoryPerformanceInstrumentation.runIfRequested(
                                model: tabsModel.activeModel
                            )
                        }
                    }
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
        }
        .defaultSize(width: 465, height: 886)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await AppUpdater.check(userInitiated: true) }
                }
            }

            CommandGroup(replacing: .help) {
                Button("Kvist Help") {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/hkarlsen06/Kvist#readme")!
                    )
                }
            }

            // Menu validation reads the active repository model, so publish
            // the first frame before constructing the command hierarchy.
            if hasPresentedInitialFrame {
                CommandGroup(replacing: .newItem) {
                Button("Open Repository…") {
                    tabsModel.activeModel.chooseRepository()
                }
                .keyboardShortcut("o")
                .disabled(
                    tabsModel.activeModel.isBusy
                    || tabsModel.activeModel.isSavingRepositoryFile
                    || tabsModel.activeModel.isGeneratingCommitMessage
                    || tabsModel.activeModel.hasPendingChangeOperations
                )

                Button("New Repository Tab") {
                    tabsModel.addTab()
                }
                .keyboardShortcut("t")

                // ⌘W is handled by the key monitor in KvistAppDelegate: the
                // system Close item owns that shortcut in the menu.
                Button(
                    tabsModel.isShowingOnlyEmptyTab ? "Close Window" : "Close Repository Tab"
                ) {
                    tabsModel.closeActiveTabOrWindow()
                }

                Divider()

                Button("Show Next Tab") {
                    tabsModel.selectNext()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(tabsModel.tabs.count < 2)

                Button("Show Previous Tab") {
                    tabsModel.selectPrevious()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(tabsModel.tabs.count < 2)
            }

            CommandGroup(after: .newItem) {
                Divider()

                Button("Save File") {
                    Task { await tabsModel.activeModel.saveRepositoryFile() }
                }
                .keyboardShortcut("s")
                .disabled(!tabsModel.activeModel.canSaveRepositoryFile)
            }

            CommandGroup(before: .toolbar) {
                Button("Show Git") {
                    tabsModel.activeModel.setWorkspaceMode(.sourceControl)
                }
                .keyboardShortcut("1")
                .disabled(tabsModel.activeModel.isPlainFolder)

                Button("Show Files") {
                    tabsModel.activeModel.setWorkspaceMode(.fileEditor)
                }
                .keyboardShortcut("2")
                .disabled(tabsModel.activeModel.repositoryURL == nil)

                Button(
                    tabsModel.activeModel.workspaceMode == .sourceControl
                        ? "Switch to Files"
                        : "Switch to Git"
                ) {
                    tabsModel.activeModel.toggleWorkspaceMode()
                }
                .keyboardShortcut(.tab, modifiers: [.control])
                .disabled(
                    tabsModel.activeModel.repositoryURL == nil
                        || tabsModel.activeModel.isPlainFolder
                )

                Divider()

                Button("Show Changes for This File") {
                    tabsModel.activeModel.showChangesForCurrentFile()
                }
                .disabled(!tabsModel.activeModel.canShowChangesForCurrentFile)

                Divider()
            }

            CommandGroup(after: .toolbar) {
                Button("Close Editor Panel") {
                    tabsModel.activeModel.closeEditorPanel()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!tabsModel.activeModel.isDiffPanelPresented)
            }

            CommandMenu("Repository") {
                Button("Refresh") {
                    Task { await tabsModel.activeModel.refresh() }
                }
                .keyboardShortcut("r")
                .disabled(
                    tabsModel.activeModel.repositoryURL == nil
                    || tabsModel.activeModel.isBusy
                    || tabsModel.activeModel.isSavingRepositoryFile
                    || tabsModel.activeModel.isGeneratingCommitMessage
                    || tabsModel.activeModel.hasPendingChangeOperations
                )

                Divider()

                Button("Fetch") {
                    Task { await tabsModel.activeModel.fetch() }
                }
                .disabled(!repositoryOperationAvailable)

                Button("Pull") {
                    Task { await tabsModel.activeModel.pull() }
                }
                .disabled(
                    !repositoryOperationAvailable
                        || !tabsModel.activeModel.hasUpstream
                )

                Button(
                    tabsModel.activeModel.hasUpstream
                        ? "Push"
                        : "Publish Branch"
                ) {
                    Task { await tabsModel.activeModel.pushOrPublish() }
                }
                .disabled(
                    !repositoryOperationAvailable
                        || (!tabsModel.activeModel.hasUpstream
                            && (tabsModel.activeModel.branch == "detached HEAD"
                                || tabsModel.activeModel.headHash == nil))
                )

                Button("Sync Changes") {
                    Task { await tabsModel.activeModel.sync() }
                }
                .disabled(
                    !repositoryOperationAvailable
                        || !tabsModel.activeModel.hasUpstream
                )

                Divider()

                Button("Commit") {
                    Task {
                        if tabsModel.activeModel.isAmendingCommit {
                            await tabsModel.activeModel.amend()
                        } else {
                            await tabsModel.activeModel.commit()
                        }
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(
                    (!tabsModel.activeModel.isAmendingCommit
                        && !tabsModel.activeModel.hasChanges)
                        || tabsModel.activeModel.isBusy
                        || tabsModel.activeModel.isSavingRepositoryFile
                        || tabsModel.activeModel.hasPendingChangeOperations
                        || tabsModel.activeModel.isGeneratingCommitMessage
                )
                }
            }
        }

        Settings {
            if hasPresentedInitialFrame {
                PreferencesView()
                    .environmentObject(themePreferences)
            } else {
                EmptyView()
            }
        }

    }

    private var repositoryOperationAvailable: Bool {
        tabsModel.activeModel.repositoryURL != nil
            && !tabsModel.activeModel.isBusy
            && !tabsModel.activeModel.isSavingRepositoryFile
            && !tabsModel.activeModel.isGeneratingCommitMessage
            && !tabsModel.activeModel.hasPendingChangeOperations
    }
}

private struct InitialWindowContent: View {
    var body: some View {
        Color(nsColor: AppTheme.canvasNSColor)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

@MainActor
private final class KvistAppDelegate: NSObject, NSApplicationDelegate {
    weak var tabsModel: WorkspaceTabsModel?
    private var tabCycleKeyMonitor: Any?

    // Option-Tab / Option-Shift-Tab cycle repository tabs. Menu items can
    // only carry one key equivalent (⌘⇧] / ⌘⇧[), so the alternates are
    // handled with an event monitor instead of duplicate menu entries.
    // ⌘W closes the repository tab here too: the monitor runs before menu
    // dispatch, and the system Close item keeps ⌘W in the menu itself.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Kvist draws its own repository tabs; macOS window tabs would add a
        // second, unrelated tab bar and View menu items.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        KvistPerformanceInstrumentation.runGitMeasurementsIfRequested()
        tabCycleKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let tabsModel = self?.tabsModel,
                  NSApp.modalWindow == nil,
                  let window = event.window,
                  window === WindowConfigurator.mainWindow,
                  window.attachedSheet == nil else { return event }
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
            // Match the typed character, not the key position, so AZERTY's
            // ⌘Z or Dvorak's ⌘, never closes a tab.
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
                tabsModel.closeActiveTabOrWindow()
                return nil
            }
            guard event.keyCode == 48 else { return event }
            if flags == .option {
                tabsModel.selectNext()
                return nil
            }
            if flags == [.option, .shift] {
                tabsModel.selectPrevious()
                return nil
            }
            return event
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if KvistPerformanceInstrumentation.configuration == nil {
            AppUpdater.checkAutomaticallyIfDue()
        }
        tabsModel?.retryMissingActiveTab()
        guard let model = tabsModel?.activeModel,
              model.sshRepository != nil else { return }
        Task { await model.refresh() }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        // The updater already asked before replacing the app.
        guard !AppUpdater.isRelaunching else { return .terminateNow }
        return tabsModel?.prepareToQuit() == false ? .terminateCancel : .terminateNow
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    @MainActor static weak var mainWindow: NSWindow?
    let didDisplayInitialFrame: () -> Void

    init(didDisplayInitialFrame: @escaping () -> Void = {}) {
        self.didDisplayInitialFrame = didDisplayInitialFrame
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(didDisplayInitialFrame: didDisplayInitialFrame)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        DispatchQueue.main.async {
            context.coordinator.configureIfNeeded(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.window != nil {
            context.coordinator.configureIfNeeded(nsView.window)
        } else {
            DispatchQueue.main.async {
                context.coordinator.configureIfNeeded(nsView.window)
            }
        }
    }

    @MainActor
    final class Coordinator {
        private let didDisplayInitialFrame: () -> Void
        private weak var configuredWindow: NSWindow?

        init(didDisplayInitialFrame: @escaping () -> Void) {
            self.didDisplayInitialFrame = didDisplayInitialFrame
        }

        func configureIfNeeded(_ window: NSWindow?) {
            guard let window, configuredWindow !== window else { return }
            configuredWindow = window
            WindowConfigurator.mainWindow = window
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
            // Keep content gestures, including the Changes/Graph resize handle,
            // from being interpreted as window drags. The tab row occupies the
            // titlebar region and provides window dragging via WindowDragArea.
            window.isMovableByWindowBackground = false
            // Disable AppKit/window-server-initiated dragging for the titlebar
            // region entirely: it runs server-side on modern macOS and would
            // move the window during ⌘-drag tab reordering even though the
            // event monitor consumes the mouse events. All window dragging
            // goes through WindowDragArea's explicit performDrag instead.
            window.isMovable = false
            window.backgroundColor = AppTheme.canvasNSColor
            window.standardWindowButton(.closeButton)?.isHidden = false
            window.standardWindowButton(.miniaturizeButton)?.isHidden = false
            window.standardWindowButton(.zoomButton)?.isHidden = false
            // The window and its SwiftUI hierarchy are installed at this point.
            // Render immediately instead of paying another main-run-loop turn;
            // model activation remains deferred by the caller to avoid changing
            // observable state during view reconciliation.
            window.displayIfNeeded()
            CATransaction.flush()
            didDisplayInitialFrame()
        }
    }
}

import AppKit
import SwiftUI

enum AppTheme {
    private(set) static var palette = AppThemePalette.ayuDark

    static func apply(_ palette: AppThemePalette) {
        self.palette = palette
    }

    // Surfaces
    static var canvas: Color { Color(hex: palette.canvas) }
    static var edge: Color { Color(hex: palette.edge) }
    static var inputFill: Color { Color(hex: palette.inputFill) }
    static var hover: Color { Color(hex: palette.hover) }
    static var raisedFill: Color { Color(hex: palette.raisedFill) }
    static var diffCanvas: Color { Color(hex: palette.diffCanvas) }
    static var disabledFill: Color { Color(hex: palette.disabledFill) }
    /// Recessed fill for the tab strip. Always darker than the canvas so the
    /// active tab and the panel it merges into read as one elevated surface
    /// in front of the strip (browser-style), never as content showing
    /// through a slot in a raised bar.
    static var tabStripFill: Color {
        let isDark = ColorMath.luminance(palette.canvas) < 0.5
        return Color(hex: ColorMath.mix(palette.canvas, 0x000000, isDark ? 0.28 : 0.10))
    }
    /// Hairline around the active tab and along the strip's bottom edge.
    /// Near-black canvases leave almost no room for a darker strip, so this
    /// line, not the fill, is what separates the active tab from the rest.
    /// Mixing toward the text color keeps it visible in light and dark themes.
    static var tabOutline: Color {
        Color(hex: ColorMath.mix(palette.canvas, palette.primary, 0.16))
    }
    static var selection: Color { Color(hex: palette.selection).opacity(0.26) }
    static var selectionNSColor: NSColor {
        NSColor(hex: palette.selection).withAlphaComponent(0.26)
    }

    // Text
    static var primary: Color { Color(hex: palette.primary) }
    static var secondary: Color { Color(hex: palette.secondary) }
    static var muted: Color { Color(hex: palette.muted) }
    static var onAccent: Color { Color(hex: palette.onAccent) }
    static var onPill: Color { Color(hex: palette.onPill) }
    static var badgeText: Color { Color(hex: palette.badgeText) }

    // Accents
    static var actionBlue: Color { Color(hex: palette.actionBlue) }
    static var graphBlue: Color { Color(hex: palette.graphBlue) }
    static var graphRemote: Color { Color(hex: palette.graphRemote) }
    static var graphReferenceBackground: Color { Color(hex: palette.graphReferenceBackground) }
    static var badgeBlue: Color { Color(hex: palette.badgeBlue) }
    static var inputBorder: Color { Color(hex: palette.inputBorder) }

    // File status colors
    static var modified: Color { Color(hex: palette.modified) }
    static var added: Color { Color(hex: palette.added) }
    static var deleted: Color { Color(hex: palette.deleted) }
    static var conflict: Color { Color(hex: palette.conflict) }
    static var swift: Color { Color(hex: palette.swift) }

    /// Graph lanes cycle through fixed hues; adjust them so they stay
    /// visible against whichever canvas the active theme brings.
    static func graphLane(_ hex: UInt32) -> Color {
        Color(hex: ColorMath.ensureContrast(hex, over: palette.canvas, ratio: 2.2))
    }

    static var canvasNSColor: NSColor { NSColor(hex: palette.canvas) }
    static var diffCanvasNSColor: NSColor { NSColor(hex: palette.diffCanvas) }
    static var primaryNSColor: NSColor { NSColor(hex: palette.primary) }
    static var secondaryNSColor: NSColor { NSColor(hex: palette.secondary) }
    static var mutedNSColor: NSColor { NSColor(hex: palette.muted) }
    static var graphBlueNSColor: NSColor { NSColor(hex: palette.graphBlue) }
    static var addedNSColor: NSColor { NSColor(hex: palette.added) }
    static var conflictNSColor: NSColor { NSColor(hex: palette.conflict) }
}

/// Panel-wide type scale. Every text style in the app draws from this ramp so
/// hierarchy stays consistent: panel titles < supporting detail < row content.
enum AppType {
    /// Uppercase panel titles (CHANGES, GRAPH).
    static let panelTitle = Font.system(size: 13, weight: .semibold)
    /// Section headers such as "Staged Changes".
    static let sectionTitle = Font.system(size: 15, weight: .semibold)
    /// Primary row content: filenames and commit subjects.
    static let row = Font.system(size: 15)
    static let rowEmphasis = Font.system(size: 15, weight: .semibold)
    /// Supporting labels beside row content: paths and branch names.
    static let rowDetail = Font.system(size: 13)
    /// Nested rows inside graph expansions.
    /// Counts, pagination, hints, and the status strip.
    static let caption = Font.system(size: 12)
    static let captionEmphasis = Font.system(size: 12, weight: .medium)
    /// Single-letter Git status codes.
    static let statusLetter = Font.system(size: 13, weight: .semibold, design: .monospaced)
}

/// Shared file-type iconography so working-tree rows and history rows always
/// render the same glyph for the same file.
enum FileGlyph {
    static func symbol(forPath path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "swift":
            return "swift"
        case "md", "txt", "rst":
            return "doc.text"
        case "json", "yml", "yaml", "toml", "plist", "xcconfig":
            return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "icns", "pdf":
            return "photo"
        case "sh", "zsh", "bash", "fish":
            return "terminal"
        case "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs", "c", "h",
             "cpp", "hpp", "m", "mm", "java", "kt", "cs", "html", "css", "scss":
            return "chevron.left.forwardslash.chevron.right"
        default:
            return "doc"
        }
    }

    static func color(forSymbol symbol: String) -> Color {
        symbol == "swift" ? AppTheme.swift : AppTheme.secondary
    }
}

/// File icon shared by every row: the active icon pack's image when one is
/// selected, otherwise the built-in SF Symbol glyph.
struct FileIconView: View {
    let path: String
    var size: CGFloat = 14
    var width: CGFloat = 21

    var body: some View {
        if let image = AppIcons.image(forPath: path) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size + 2, height: size + 2)
                .frame(width: width)
        } else {
            let symbol = FileGlyph.symbol(forPath: path)
            Image(systemName: symbol)
                .font(.system(size: symbol == "swift" ? size + 3 : size, weight: .regular))
                .foregroundStyle(FileGlyph.color(forSymbol: symbol))
                .frame(width: width)
        }
    }
}

struct FolderIconView: View {
    let expanded: Bool
    var size: CGFloat = 13
    var width: CGFloat = 19

    var body: some View {
        if let image = AppIcons.folderImage(expanded: expanded) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size + 2, height: size + 2)
                .frame(width: width)
        } else {
            Image(systemName: expanded ? "folder.fill" : "folder")
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(AppTheme.secondary)
                .frame(width: width)
        }
    }
}

/// The VS Code Codicon "git-branch" (CC BY 4.0, see THIRD_PARTY_NOTICES).
struct BranchGlyph: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        CodiconGlyph(icon: .gitBranch, size: size, color: color)
    }
}

struct SSHLogo: View {
    private static let image = Bundle.kvistResources.url(
        forResource: "Unofficial_SSH_Logo",
        withExtension: "svg"
    ).flatMap(NSImage.init(contentsOf:))

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        }
    }
}
struct ContentView: View {
    @EnvironmentObject private var tabsModel: WorkspaceTabsModel

    var body: some View {
        VStack(spacing: 0) {
            RepositoryTopBar()

            RepositoryWorktreeBar(tab: tabsModel.activeTab)

            ActiveRepositoryView(tab: tabsModel.activeTab)

            RepositoryStatusBar(tab: tabsModel.activeTab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.canvas)
        .foregroundStyle(AppTheme.primary)
        .ignoresSafeArea(edges: .top)
    }
}

struct RepositoryModePicker: View {
    @EnvironmentObject private var model: RepositoryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(RepositoryWorkspaceMode.allCases) { mode in
                RepositoryModeSegment(
                    mode: mode,
                    isSelected: mode == model.workspaceMode,
                    selectionNamespace: selectionNamespace
                ) {
                    guard mode != model.workspaceMode else { return }
                    if reduceMotion {
                        model.setWorkspaceMode(mode)
                    } else {
                        withAnimation(.easeOut(duration: 0.14)) {
                            model.setWorkspaceMode(mode)
                        }
                    }
                }
            }
        }
        // 2pt inset keeps the selection pill nearly flush with the capsule,
        // matching the proportions of Xcode's navigator switcher.
        .padding(2)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace Mode")
        .accessibilityValue(model.workspaceMode.title)
    }
}

struct RepositoryTerminalButton: View {
    @EnvironmentObject private var model: RepositoryModel

    var body: some View {
        Button {
            openRepositoryInTerminal()
        } label: {
            Image(systemName: "apple.terminal")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.secondary)
        .disabled(model.repositoryURL == nil)
        .accessibilityLabel("Open Repository in Terminal")
        .help("Open Repository in Terminal")
    }

    private func openRepositoryInTerminal() {
        guard let repositoryURL = model.repositoryURL else { return }
        do {
            try RepositoryTerminalLauncher.open(
                repositoryURL: repositoryURL,
                sshRepository: model.sshRepository
            ) { error in
                Task { @MainActor in
                    model.errorMessage = error.localizedDescription
                }
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

@MainActor
enum RepositoryLocationSymbol {
    static let image: NSImage? = {
        let image = NSImage(
            systemSymbolName: "folder.badge.gearshape",
            accessibilityDescription: nil
        ) ?? NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        guard let image else { return nil }
        image.isTemplate = true
        return image
    }()
}

@MainActor
enum RepositoryLocationActions {
    static func copyDirectoryPath(
        _ repositoryURL: URL,
        to pasteboard: NSPasteboard = .general
    ) {
        pasteboard.clearContents()
        pasteboard.setString(
            repositoryURL.standardizedFileURL.path,
            forType: .string
        )
    }

    static func revealInFinder(_ repositoryURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([
            repositoryURL.standardizedFileURL
        ])
    }
}

struct RepositoryLocationMenu: View {
    @EnvironmentObject private var model: RepositoryModel

    var body: some View {
        Menu {
            Button("Copy Directory as Path") {
                if let sshRepository = model.sshRepository {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sshRepository.location(), forType: .string)
                    return
                }
                guard let repositoryURL = model.repositoryURL else { return }
                RepositoryLocationActions.copyDirectoryPath(repositoryURL)
            }

            if model.sshRepository == nil {
                Button("Reveal in Finder") {
                    guard let repositoryURL = model.repositoryURL else { return }
                    RepositoryLocationActions.revealInFinder(repositoryURL)
                }
            }
        } label: {
            if let image = RepositoryLocationSymbol.image {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 16)
                    .frame(width: 24, height: 26)
                    .contentShape(Rectangle())
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24, height: 26)
        .foregroundStyle(AppTheme.secondary)
        .tint(AppTheme.secondary)
        .disabled(model.repositoryURL == nil)
        .accessibilityLabel("Repository Location")
        .help("Repository Location")
    }
}

struct RepositoryModeSegment: View {
    let mode: RepositoryWorkspaceMode
    let isSelected: Bool
    let selectionNamespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if mode == .sourceControl {
                    BranchGlyph(size: 14, color: iconColor)
                } else {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
            }
            .frame(width: 36, height: 26)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(AppTheme.raisedFill)
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                            .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                    } else if hovering {
                        Capsule()
                            .fill(AppTheme.hover.opacity(0.6))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(mode.title) (\(mode.shortcutHint))")
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var iconColor: Color {
        if isSelected { return AppTheme.primary }
        return hovering ? AppTheme.secondary : AppTheme.muted
    }
}

struct RepositoryContentView: View {
    @EnvironmentObject private var model: RepositoryModel
    let isRepositoryLoadPending: Bool
    let pendingRepositoryName: String

    var body: some View {
        Group {
            if let url = model.repositoryInitializationURL {
                InitializeRepositoryView(folderURL: url)
            } else if model.repositoryURL == nil {
                if model.isBusy || isRepositoryLoadPending {
                    RepositoryLoadingView(repositoryName: pendingRepositoryName)
                } else {
                    WelcomeView()
                }
            } else {
                switch model.workspaceMode {
                case .sourceControl:
                    WorkspaceView()
                case .fileEditor:
                    RepositoryFileBrowser()
                }
            }
        }
        .onChange(of: model.errorPresentation) { _, presentation in
            guard let presentation else { return }
            DispatchQueue.main.async {
                AppDialog.message(
                    title: presentation.title,
                    message: presentation.message,
                    details: presentation.details
                )
                if model.errorPresentation == presentation {
                    model.errorPresentation = nil
                }
            }
        }
    }
}

struct MissingFolderView: View {
    @EnvironmentObject private var tabsModel: WorkspaceTabsModel
    @ObservedObject var tab: RepositoryTab

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(AppTheme.muted)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("\(tab.displayName) is not available")
                    .font(.system(size: 16, weight: .semibold))

                Text(message)
                    .font(AppType.rowDetail)
                    .foregroundStyle(AppTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 30)

            Button("Try Again") {
                tabsModel.retryMissingActiveTab()
            }
            .buttonStyle(PrimaryButtonStyle())
            .frame(width: 210, height: 34)

            Button("Close Tab") {
                tabsModel.closeTab(tab.id)
            }
            .buttonStyle(.plain)
            .font(AppType.rowDetail)
            .foregroundStyle(AppTheme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var message: String {
        let path = (tab.repositoryURL?.path ?? "") as NSString
        var text = "Kvist can't find \(path.abbreviatingWithTildeInPath). "
            + "It may be on a drive that isn't connected, or it was moved or deleted."
        if tab.hasRecoveredDraft {
            text += " Unsaved edits from the last session are kept until the folder is back."
        }
        return text
    }
}

struct RepositoryLoadingView: View {
    let repositoryName: String

    var body: some View {
        WorkspaceView(isOpeningRepository: true)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Opening \(repositoryName)")
            .accessibilityAddTraits(.updatesFrequently)
    }
}

struct InitializeRepositoryView: View {
    @EnvironmentObject private var model: RepositoryModel
    let folderURL: URL

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(AppTheme.graphBlue)

                VStack(spacing: 5) {
                    Text("Initialize Git Repository")
                        .font(.system(size: 16, weight: .semibold))

                    Text(folderURL.lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(
                        model.sshRepository.map {
                            "This folder on \($0.host) is not currently tracked by Git."
                        } ?? "This folder is not currently tracked by Git."
                    )
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.muted)
                }

                Button("Initialize with .gitignore") {
                    Task { await model.initializeRepository(createGitIgnore: true) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(width: 210, height: 36)
                .disabled(model.isBusy)

                HStack(spacing: 16) {
                    Button("Initialize without .gitignore") {
                        Task { await model.initializeRepository(createGitIgnore: false) }
                    }
                    .buttonStyle(.plain)

                    if !model.isPlainFolder {
                        Button("Browse Files Without Git") {
                            Task { await model.browseFolderWithoutGit() }
                        }
                        .buttonStyle(.plain)
                        .help("Open this folder as a file browser and editor")
                    }

                    Button("Choose Another Folder…") {
                        model.chooseRepository()
                    }
                    .buttonStyle(.plain)

                    Button("Back") {
                        model.cancelRepositoryInitialization()
                    }
                    .buttonStyle(.plain)

                }
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.secondary)
                .disabled(model.isBusy)
            }
            .padding(.horizontal, 28)

            Spacer()
        }
        .accessibilityElement(children: .contain)
    }
}

struct SSHBrowserSession: Identifiable {
    let id = UUID()
    let host: String
}

struct WelcomeView: View {
    @EnvironmentObject private var model: RepositoryModel
    @EnvironmentObject private var tabsModel: WorkspaceTabsModel
    @State private var isDropTargeted = false
    @State private var sshBrowserSession: SSHBrowserSession?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            VStack(spacing: 16) {
                BranchGlyph(size: 38, color: AppTheme.graphBlue)

                VStack(spacing: 6) {
                    Text("Open a repository or folder")
                        .font(.system(size: 16, weight: .semibold))

                    Text("Drop a folder here, or press ⌘O to browse.")
                        .font(AppType.rowDetail)
                        .foregroundStyle(AppTheme.muted)
                }

                Button("Open Repository…") {
                    model.chooseRepository()
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(width: 210, height: 34)
                .disabled(
                    model.isBusy
                        || model.isGeneratingCommitMessage
                        || model.hasPendingChangeOperations
                )

                Button("Clone Repository…") {
                    cloneRepository()
                }
                .buttonStyle(.plain)
                .font(AppType.rowDetail)
                .foregroundStyle(AppTheme.secondary)
                .disabled(
                    model.isBusy
                        || model.isGeneratingCommitMessage
                        || model.hasPendingChangeOperations
                )
                .help("Clone a remote repository into a local folder")

                Button("Open Repository over SSH…") {
                    openSSHRepository()
                }
                .buttonStyle(.plain)
                .font(AppType.rowDetail)
                .foregroundStyle(AppTheme.secondary)
                .disabled(
                    model.isBusy
                        || model.isGeneratingCommitMessage
                        || model.hasPendingChangeOperations
                )
                .help("Browse and edit files on a remote machine, with Git when the folder is a repository")
            }

            RepositoryPickerList()
                .padding(.top, 34)

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        AppTheme.graphBlue,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .background(
                        AppTheme.graphBlue.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard !model.isBusy, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    await model.openRepository(directoryURL(for: url))
                }
            }
            return true
        }
        .sheet(item: $sshBrowserSession) { session in
            SSHRepositoryBrowserView(host: session.host) { path in
                Task {
                    await model.openSSHRepository(host: session.host, path: path)
                }
            }
        }
    }

    private func openSSHRepository() {
        guard let location = GitPrompt.sshRepository() else { return }
        if location.path.isEmpty {
            sshBrowserSession = SSHBrowserSession(host: location.host)
            return
        }
        Task {
            await model.openSSHRepository(host: location.host, path: location.path)
        }
    }

    private func cloneRepository() {
        guard let remoteURL = GitPrompt.cloneRemoteURL(),
              let destinationURL = GitPrompt.cloneDestinationFolder() else { return }
        Task {
            await model.cloneRepository(from: remoteURL, to: destinationURL)
        }
    }

    /// Dropping a file inside a repository should open its enclosing folder.
    private func directoryURL(for url: URL) -> URL {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue ? url : url.deletingLastPathComponent()
    }
}

struct WorkspaceView: View {
    let isOpeningRepository: Bool

    init(isOpeningRepository: Bool = false) {
        self.isOpeningRepository = isOpeningRepository
    }

    @AppStorage("graphPanelHeight") private var graphPanelHeight = 260.0
    @State private var graphHeightAtDragStart: CGFloat?

    private let resizeHandleHeight: CGFloat = 5
    private let minimumChangesHeight: CGFloat = 175
    private let minimumGraphHeight: CGFloat = 98

    var body: some View {
        GeometryReader { geometry in
            let graphRange = minimumGraphHeight...maximumGraphHeight(
                availableHeight: geometry.size.height
            )
            let resolvedGraphHeight = min(
                max(CGFloat(graphPanelHeight), graphRange.lowerBound),
                graphRange.upperBound
            )

            VStack(spacing: 0) {
                ChangesPanel(isOpeningRepository: isOpeningRepository)
                    .frame(maxHeight: .infinity)

                GraphResizeHandle(
                    height: $graphPanelHeight,
                    heightAtDragStart: $graphHeightAtDragStart,
                    currentHeight: resolvedGraphHeight,
                    allowedRange: graphRange
                )

                GraphPanel(isOpeningRepository: isOpeningRepository)
                    .frame(height: resolvedGraphHeight)
            }
        }
        .clipped()
    }

    private func maximumGraphHeight(availableHeight: CGFloat) -> CGFloat {
        max(
            minimumGraphHeight,
            availableHeight
                - resizeHandleHeight
                - minimumChangesHeight
        )
    }
}

struct GraphResizeHandle: View {
    @Binding var height: Double
    @Binding var heightAtDragStart: CGFloat?
    let currentHeight: CGFloat
    let allowedRange: ClosedRange<CGFloat>
    @State private var isHovered = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 5)
            .overlay {
                Rectangle()
                    .fill(
                        isHovered || heightAtDragStart != nil
                            ? AppTheme.actionBlue
                            : AppTheme.edge
                    )
                    .frame(height: 1)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovered {
                    NSCursor.pop()
                    isHovered = false
                }
                heightAtDragStart = nil
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if heightAtDragStart == nil {
                            heightAtDragStart = currentHeight
                        }
                        guard let heightAtDragStart else { return }
                        height = Double(clamp(
                            heightAtDragStart - value.translation.height
                        ))
                    }
                    .onEnded { value in
                        heightAtDragStart = nil
                        if NSApp.currentEvent?.clickCount == 2,
                           abs(value.translation.height) < 2 {
                            height = Double(clamp(260))
                        }
                    }
            )
            .accessibilityLabel("Resize graph")
            .accessibilityValue("\(Int(currentHeight)) points")
            .help("Drag to resize the graph. Double-click to reset.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    height = Double(clamp(currentHeight + 24))
                case .decrement:
                    height = Double(clamp(currentHeight - 24))
                @unknown default:
                    break
                }
            }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, allowedRange.lowerBound), allowedRange.upperBound)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }

    /// ButtonStyle has no access to the enabled state; a view does.
    private struct PrimaryButtonBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isEnabled ? AppTheme.onAccent : AppTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    !isEnabled
                        ? AppTheme.disabledFill
                        : configuration.isPressed
                            ? AppTheme.actionBlue.opacity(0.78)
                            : AppTheme.actionBlue
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

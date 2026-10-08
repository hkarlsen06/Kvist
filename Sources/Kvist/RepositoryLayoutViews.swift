import AppKit
import SwiftUI

/// The checkouts of the active repository, under the tab row. A checkout is
/// a folder with the repository: a linked worktree, or a clone on another
/// machine. Each one opens in its own tab so it keeps its own drafts and
/// panels, and those tabs share the repository's entry in the tab row.
struct RepositoryWorktreeBar: View {
    @ObservedObject private var tab: RepositoryTab
    @ObservedObject private var model: RepositoryModel
    @EnvironmentObject private var tabsModel: WorkspaceTabsModel
    @EnvironmentObject private var registry: CheckoutRegistry

    init(tab: RepositoryTab) {
        _tab = ObservedObject(wrappedValue: tab)
        _model = ObservedObject(wrappedValue: tab.model)
    }

    var body: some View {
        // A tab still connecting to its SSH checkout has no URL yet, but
        // keeps the bar so the switch does not move the layout.
        if tab.repositoryURL != nil || tab.checkout != nil, !model.isPlainFolder {
            let checkouts = tabsModel.checkouts(shownWith: tab)
            let group = tabsModel.group(of: tab)
            let listed = group.flatMap(\.worktrees)
            let mainIDs = Set(group.compactMap(\.worktrees.first).map { Checkout(worktree: $0).id })
            let showsMachines = Set(checkouts.map(\.host)).count > 1
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        CodiconGlyph(icon: .worktree, size: 13, color: AppTheme.muted)
                            .frame(width: 20, height: 22)
                            .accessibilityHidden(true)

                        ForEach(checkouts) { checkout in
                            let isCurrent = tab.shows(checkout.worktree)
                            let state = state(of: checkout, isCurrent: isCurrent)
                            RepositoryCheckoutBarItem(
                                checkout: checkout,
                                worktree: model.worktrees.first { checkout.isSame(as: $0) } ?? checkout.worktree,
                                title: state?.branch
                                    ?? listed.first { checkout.isSame(as: $0) }?.branch
                                    ?? checkout.name,
                                machine: showsMachines ? checkout.machineName : nil,
                                state: state,
                                failure: registry.failures[checkout.id],
                                isMain: mainIDs.contains(checkout.id),
                                isCurrent: isCurrent,
                                isRemovable: isRemovable(checkout),
                                canForget: !tabsModel.isOpen(checkout)
                                    && !listed.contains { checkout.isSame(as: $0) }
                            )
                        }
                    }
                    .padding(.leading, 8)
                    .frame(height: 30)
                }
                .scrollIndicators(.never)
                .modifier(HorizontalScrollEdgeBlur(fill: AppTheme.canvas, bottomInset: 1))

                Button {
                    createWorktree()
                } label: {
                    Label("New Worktree", systemImage: "plus")
                        .font(AppType.captionEmphasis)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.secondary)
                .disabled(model.headHash == nil || isBusy)
                .help("Check out a branch in its own folder")
                .padding(.horizontal, 6)
            }
            .frame(height: 30)
            .background(AppTheme.canvas)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(AppTheme.edge)
                    .frame(height: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Checkouts")
            // Restarts when the tab or the list changes, and stops when the
            // bar leaves the screen.
            .task(id: "\(tab.id)\(checkouts.map(\.id))") {
                while !Task.isCancelled {
                    await registry.refresh(checkouts, maximumAge: 30)
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }

    /// The current checkout reads from its live model once it has loaded,
    /// since that is never stale. Others, and the current one while it
    /// loads, use the registry's last status, then their open tab's model.
    private func state(of checkout: Checkout, isCurrent: Bool) -> CheckoutBarState? {
        if isCurrent, model.repositoryURL != nil { return CheckoutBarState(model: model) }
        if let status = registry.statuses[checkout.id] { return CheckoutBarState(status: status) }
        if let other = tabsModel.tabs.first(where: { $0.shows(checkout.worktree) })?.loadedModel,
           other.repositoryURL != nil {
            return CheckoutBarState(model: other)
        }
        return nil
    }

    /// Only a linked worktree of the active repository can be removed. Git
    /// lists the main worktree first, and it cannot be removed.
    private func isRemovable(_ checkout: Checkout) -> Bool {
        !isBusy
            && model.worktrees.dropFirst().contains { checkout.isSame(as: $0) }
    }

    private var isBusy: Bool {
        model.repositoryURL == nil
            || model.isBusy
            || model.isGeneratingCommitMessage
            || model.hasPendingChangeOperations
    }

    private func createWorktree() {
        guard let input = GitPrompt.newWorktree(
            defaultPath: model.defaultWorktreePath(for: "branch")
        ) else { return }
        Task {
            if let worktree = await model.addWorktree(
                branch: input.branch,
                path: input.path
            ) {
                tabsModel.switchToWorktree(worktree)
            }
        }
    }
}

/// Blurs and fades the edges of a horizontal scroll view that hides its
/// scrollers, on each side where content is scrolled out of view. The system
/// scroll edge effect only covers top and bottom edges.
struct HorizontalScrollEdgeBlur: ViewModifier {
    let fill: Color
    var bottomInset: CGFloat = 0
    @State private var hidesLeadingContent = false
    @State private var hidesTrailingContent = false

    private let width: CGFloat = 32

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: [Bool].self) { geometry in
                let offset = geometry.contentOffset.x
                return [
                    offset > 1,
                    offset + geometry.containerSize.width < geometry.contentSize.width - 1
                ]
            } action: { _, hiddenEdges in
                hidesLeadingContent = hiddenEdges[0]
                hidesTrailingContent = hiddenEdges[1]
            }
            .overlay(alignment: .leading) {
                if hidesLeadingContent { edge(fadingTo: .trailing) }
            }
            .overlay(alignment: .trailing) {
                if hidesTrailingContent { edge(fadingTo: .leading) }
            }
    }

    /// Strongest at the scroll view's edge and gone at `end`.
    private func edge(fadingTo end: UnitPoint) -> some View {
        let start = UnitPoint(x: 1 - end.x, y: 0.5)
        return ZStack {
            // The blur stops before the color fade does, because past that
            // point the fade is too thin to hide the material's tint.
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(LinearGradient(
                    stops: [.init(color: .black, location: 0), .init(color: .clear, location: 0.6)],
                    startPoint: start,
                    endPoint: end
                ))
            // Covers the material's tint at the edge, where it would
            // otherwise show as a lighter band on dark strips.
            LinearGradient(
                colors: [fill, fill.opacity(0.85), fill.opacity(0.4), fill.opacity(0)],
                startPoint: start,
                endPoint: end
            )
        }
        .frame(width: width)
        .padding(.bottom, bottomInset)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What the bar shows about one checkout, from its open model or the last
/// status the registry read.
struct CheckoutBarState {
    var branch: String?
    var ahead = 0
    var behind = 0
    var changes = 0

    init(branch: String?, ahead: Int, behind: Int, changes: Int) {
        self.branch = branch == "detached HEAD" || branch?.isEmpty == true ? nil : branch
        self.ahead = ahead
        self.behind = behind
        self.changes = changes
    }

    @MainActor
    init(model: RepositoryModel) {
        self.init(
            branch: model.branch,
            ahead: model.ahead,
            behind: model.behind,
            changes: Set(model.staged.map(\.path)).union(model.unstaged.map(\.path)).count
        )
    }

    init(status: CheckoutStatus) {
        self.init(
            branch: status.branch,
            ahead: status.ahead,
            behind: status.behind,
            changes: status.changeCount
        )
    }

    var summary: String {
        var parts = [changes == 0 ? "Clean" : "\(changes) changed \(changes == 1 ? "file" : "files")"]
        if ahead > 0 { parts.append("\(ahead) ahead") }
        if behind > 0 { parts.append("\(behind) behind") }
        return parts.joined(separator: ", ")
    }
}

struct RepositoryCheckoutBarItem: View {
    @EnvironmentObject private var tabsModel: WorkspaceTabsModel
    @EnvironmentObject private var registry: CheckoutRegistry
    let checkout: Checkout
    /// The worktree as Git lists it, which removing needs.
    let worktree: GitWorktree
    let title: String
    /// Set when the bar lists more than one machine.
    let machine: String?
    let state: CheckoutBarState?
    /// The last error reading this checkout, such as an unreachable host.
    let failure: String?
    let isMain: Bool
    let isCurrent: Bool
    let isRemovable: Bool
    /// No tab shows the checkout and no open repository lists it as a worktree.
    let canForget: Bool
    @State private var hovering = false

    private var location: String {
        isMain ? "Main worktree at \(checkout.location)" : checkout.location
    }

    private var details: String {
        failure ?? state?.summary ?? "Status not read yet"
    }

    var body: some View {
        Button {
            tabsModel.open(checkout)
        } label: {
            HStack(spacing: 5) {
                if let machine {
                    Text(machine)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(AppTheme.muted)
                }

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                if let state, failure == nil {
                    if state.changes > 0 {
                        Circle()
                            .fill(AppTheme.modified)
                            .frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                    }
                    if state.ahead > 0 {
                        Text("↑\(state.ahead)")
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.muted)
                    }
                    if state.behind > 0 {
                        Text("↓\(state.behind)")
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.muted)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background {
                if isCurrent || hovering {
                    RoundedRectangle(cornerRadius: 5)
                        // Some themes derive raisedFill from the canvas, which
                        // would hide the current checkout.
                        .fill(isCurrent ? AppTheme.selection : AppTheme.hover)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isCurrent ? AppTheme.primary : AppTheme.secondary)
        .opacity(failure == nil ? 1 : 0.5)
        .onHover { hovering = $0 }
        .help("\(location)\n\(details)")
        .accessibilityLabel(machine.map { "\($0), \(title)" } ?? title)
        .accessibilityValue(details)
        .accessibilityHint(location)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .contextMenu {
            if checkout.host == nil {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([checkout.worktree.url])
                }
            }

            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(checkout.path, forType: .string)
            }

            Divider()

            Button("Remove Worktree…") {
                guard GitPrompt.confirmRemoveWorktree(worktree) else { return }
                tabsModel.removeWorktree(worktree)
            }
            .disabled(!isRemovable)

            if canForget {
                Button("Remove from Kvist") {
                    registry.remove(checkout.id)
                }
            }
        }
    }
}

struct RepositoryStatusBar: View {
    @ObservedObject private var tab: RepositoryTab
    @ObservedObject var model: RepositoryModel

    init(tab: RepositoryTab) {
        _tab = ObservedObject(wrappedValue: tab)
        _model = ObservedObject(wrappedValue: tab.model)
    }

    var body: some View {
        HStack(spacing: 0) {
            if model.repositoryURL != nil, model.isPlainFolder {
                plainFolderLabel

                Spacer(minLength: 0)

                if showsActivity {
                    activityLabel

                    Spacer(minLength: 0)
                }
            } else if model.repositoryURL != nil {
                branchMenu

                Spacer(minLength: 0)

                if model.activeOperation != nil {
                    activeOperationControls

                    Spacer(minLength: 0)
                } else if showsActivity {
                    activityLabel

                    Spacer(minLength: 0)
                }

                syncButton
            } else if model.isBusy || tab.isRepositoryLoadPending {
                Spacer(minLength: 0)

                activityLabel

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        // Matches the 34pt top tab bar.
        .frame(height: 34)
        .background(AppTheme.inputFill)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.edge)
                .frame(height: 1)
        }
        .foregroundStyle(AppTheme.primary)
        .accessibilityElement(children: .contain)
    }

    private var plainFolderLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.secondary)
            Text(model.repositoryURL?.lastPathComponent ?? "Folder")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Not a Git repository") {
                model.requestRepositoryInitialization()
            }
            .buttonStyle(.plain)
            .font(AppType.caption)
            .foregroundStyle(AppTheme.muted)
            .disabled(model.isBusy)
            .accessibilityLabel("Initialize Git Repository")
            .help("Initialize a Git repository in this folder")
        }
        .accessibilityElement(children: .contain)
    }

    private var branchMenu: some View {
        Menu {
            Button("New Branch…") {
                guard let name = GitPrompt.branchName(from: model.branch) else { return }
                Task { await model.createBranchAtHead(named: name) }
            }
            .disabled(model.headHash == nil)

            Button("Rename Current Branch…") {
                guard let reference = currentBranchReference,
                      let name = GitPrompt.renamedBranch(reference) else { return }
                Task { await model.renameBranch(reference, to: name) }
            }
            .disabled(currentBranchReference == nil)

            Menu("Upstream") {
                if remoteBranches.isEmpty {
                    Text("No remote branches")
                } else {
                    ForEach(remoteBranches) { reference in
                        Button {
                            Task { await model.setUpstream(reference) }
                        } label: {
                            if reference.id == model.upstreamReference?.id {
                                Label(reference.name, systemImage: "checkmark")
                            } else {
                                Text(reference.name)
                            }
                        }
                    }
                }

                if model.hasUpstream {
                    Divider()

                    Button("Unset Upstream") {
                        Task { await model.unsetUpstream() }
                    }
                }
            }
            .disabled(model.branch == "detached HEAD" || model.headHash == nil)

            Divider()

            if localBranches.isEmpty && remoteBranches.isEmpty {
                Text(model.repositoryURL == nil ? "Open a repository first" : "No branches")
            } else {
                if !localBranches.isEmpty {
                    Section("Branches") {
                        ForEach(localBranches) { reference in
                            branchMenuItem(reference)
                        }
                    }
                }

                if !remoteBranches.isEmpty {
                    Section("Remote Branches") {
                        ForEach(remoteBranches) { reference in
                            branchMenuItem(reference)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                branchIcon

                Text(branchLabel)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 250, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(AppTheme.primary)
        .help("Checkout Branch…")
        .accessibilityLabel("Current branch: \(branchLabel)")
        .disabled(branchMenuDisabled)
    }

    private var branchMenuDisabled: Bool {
        model.repositoryURL == nil
            || model.isBusy
            || model.isGeneratingCommitMessage
            || model.hasPendingChangeOperations
    }

    private func branchMenuItem(_ reference: GitReference) -> some View {
        Button {
            Task { await model.checkout(reference) }
        } label: {
            if reference.isHead {
                Label(reference.name, systemImage: "checkmark")
            } else {
                Text(reference.name)
            }
        }
    }

    private var branchIcon: some View {
        ZStack(alignment: .bottomTrailing) {
            BranchGlyph(size: 14, color: AppTheme.primary)

            if model.hasStagedChanges {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppTheme.added)
                    .background(AppTheme.inputFill, in: Circle())
                    .offset(x: 3, y: 3)
            } else if !model.unstaged.isEmpty {
                Image(systemName: "circle.fill")
                    .font(.system(size: 4, weight: .bold))
                    .foregroundStyle(AppTheme.modified)
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: 18, height: 18)
    }

    private var syncButton: some View {
        Button {
            Task {
                if model.hasUpstream {
                    await model.sync()
                } else {
                    await model.publish()
                }
            }
        } label: {
            HStack(spacing: 5) {
                SpinningCodiconGlyph(
                    icon: syncIcon,
                    isSpinning: model.isSyncing && model.hasUpstream,
                    size: 14
                )

                if !syncCountLabel.isEmpty {
                    Text(syncCountLabel)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                }
            }
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.secondary)
        .disabled(syncOperationsDisabled)
        .help(syncHelp)
        .accessibilityLabel(syncHelp)
    }

    private var syncOperationsDisabled: Bool {
        model.repositoryURL == nil
            || model.isBusy
            || model.isGeneratingCommitMessage
            || model.hasPendingChangeOperations
            || (!model.hasUpstream && model.branch == "detached HEAD")
            || (!model.hasUpstream && model.headHash == nil)
    }

    private var activityLabel: some View {
        HStack(spacing: 5) {
            if activityIsInProgress {
                ProgressView()
                    .controlSize(.mini)
                    .tint(AppTheme.secondary)
            }

            Text(activityText)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
        }
        .foregroundStyle(AppTheme.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(activityText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Repository status: \(activityText)")
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private var activeOperationControls: some View {
        if let operation = model.activeOperation {
            HStack(spacing: 9) {
                Text(operation.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.secondary)

                Button("Continue") {
                    Task { await model.continueActiveOperation() }
                }
                .help("Continue " + operation.displayName.lowercased())
                .disabled(model.hasUnresolvedConflicts)

                if model.canSkipActiveOperation {
                    Button("Skip") {
                        Task { await model.skipActiveOperation() }
                    }
                    .help("Skip Current Commit")
                }

                Button("Abort…", role: .destructive) {
                    Task { await model.abortActiveOperation() }
                }
                .foregroundStyle(AppTheme.deleted)
                .help("Abort \(operation.displayName)")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .disabled(model.isBusy || model.hasPendingChangeOperations)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(operation.displayName + " in progress")
        }
    }

    private var showsActivity: Bool {
        model.activity != "Ready" && model.activity != "Up to date"
    }

    private var activityIsInProgress: Bool {
        tab.isRepositoryLoadPending
            || model.isBusy
            || model.isGeneratingCommitMessage
            || model.hasPendingChangeOperations
            || model.isLoadingMoreGraph
            || !model.loadingCommitFileHashes.isEmpty
    }

    private var activityText: String {
        if tab.isRepositoryLoadPending && !model.isBusy {
            return "Opening repository…"
        }
        return model.activity
    }

    private var localBranches: [GitReference] {
        model.references
            .filter { $0.kind == .localBranch }
            .sorted { lhs, rhs in
                if lhs.isHead != rhs.isHead { return lhs.isHead }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private var currentBranchReference: GitReference? {
        localBranches.first(where: \.isHead)
    }

    private var remoteBranches: [GitReference] {
        model.references
            .filter {
                $0.kind == .remoteBranch && !$0.name.hasSuffix("/HEAD")
            }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private var branchLabel: String {
        guard model.repositoryURL != nil else {
            return model.isBusy ? "Opening…" : "No Repository"
        }

        let head = model.branch.isEmpty ? "detached HEAD" : model.branch
        let workingTreeMarker = model.unstaged.isEmpty ? "" : "*"
        let stagedMarker = model.hasStagedChanges ? "+" : ""
        return head + workingTreeMarker + stagedMarker
    }

    private var syncIcon: Codicon {
        model.hasUpstream ? .sync : .repoPush
    }

    private var syncCountLabel: String {
        guard model.hasUpstream else { return "" }
        var parts: [String] = []
        if model.behind > 0 { parts.append("\(model.behind)↓") }
        if model.ahead > 0 { parts.append("\(model.ahead)↑") }
        return parts.joined(separator: " ")
    }

    private var syncHelp: String {
        guard model.repositoryURL != nil else { return "Open a repository" }
        guard model.hasUpstream else {
            return model.branch == "detached HEAD" ? "No upstream branch" : "Publish Branch"
        }
        if model.ahead == 0 && model.behind == 0 {
            return "Synchronize Changes"
        }
        return "Synchronize Changes\(syncCountLabel.isEmpty ? "" : " (\(syncCountLabel))")"
    }
}

struct ActiveRepositoryView: View {
    @ObservedObject private var tab: RepositoryTab
    @ObservedObject private var model: RepositoryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("repositorySplitFraction")
    private var repositorySplitFraction = RepositorySplitLayout.defaultFraction
    @State private var repositoryWidthAtDragStart: CGFloat?

    init(tab: RepositoryTab) {
        _tab = ObservedObject(wrappedValue: tab)
        _model = ObservedObject(wrappedValue: tab.model)
    }

    var body: some View {
        GeometryReader { geometry in
            let split = RepositorySplitLayout.metrics(
                totalWidth: geometry.size.width,
                preferredFraction: repositorySplitFraction,
                minimumDetailWidth: model.conflictResolution != nil
                    && !model.isFileSearchResultsPresented
                    ? RepositorySplitLayout.conflictDiffWidth
                    : RepositorySplitLayout.minimumPaneWidth
            )
            let repositoryWidth = model.isRepositorySidePanelPresented
                ? split.repositoryWidth
                : geometry.size.width

            VStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        Group {
                            if tab.isFolderMissing, model.repositoryURL == nil {
                                MissingFolderView(tab: tab)
                            } else {
                                RepositoryContentView(
                                    isRepositoryLoadPending: tab.isRepositoryLoadPending,
                                    pendingRepositoryName: tab.displayName
                                )
                            }
                        }
                        .frame(width: repositoryWidth)
                        .frame(maxHeight: .infinity)
                        .background(AppTheme.canvas)

                        if model.isRepositorySidePanelPresented {
                            Color.clear
                                .frame(width: RepositorySplitLayout.separatorWidth)

                            Group {
                                if model.isFileSearchResultsPresented {
                                    RepositorySearchResultsPanel()
                                } else {
                                    RepositoryEditorPanel()
                                }
                            }
                                .frame(width: split.detailWidth)
                                .frame(maxHeight: .infinity)
                                .clipped()
                        }
                    }

                    if model.isRepositorySidePanelPresented {
                        RepositorySplitResizeHandle(
                            fraction: $repositorySplitFraction,
                            widthAtDragStart: $repositoryWidthAtDragStart,
                            currentRepositoryWidth: split.repositoryWidth,
                            availablePaneWidth: split.availablePaneWidth,
                            allowedRepositoryWidths: split.allowedRepositoryWidths
                        )
                        .offset(
                            x: split.repositoryWidth
                                - RepositorySplitLayout.resizeHandleInset
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environmentObject(model)
        .overlay(alignment: .topLeading) {
            DiffPanelWindowExpansion(
                isExpanded: model.isRepositorySidePanelPresented,
                minimumExpandedWidth: model.conflictResolution != nil
                    && !model.isFileSearchResultsPresented
                    ? RepositorySplitLayout.conflictExpandedWidth
                    : nil,
                reduceMotion: reduceMotion
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
    }
}

enum RepositorySplitLayout {
    static let defaultFraction = 0.5
    static let repositoryWidth: CGFloat = 465
    static let separatorWidth: CGFloat = 1
    static let resizeHandleWidth: CGFloat = 5
    static let resizeHandleInset = (resizeHandleWidth - separatorWidth) / 2
    static let minimumPaneWidth: CGFloat = 300
    static let diffWidth: CGFloat = repositoryWidth
    /// The conflict resolver's toolbar needs ~526pt before its fixed labels
    /// ("Edit File Manually", "Resolve All", "Mark Resolved") start
    /// truncating; only the branch-name choice buttons may give way.
    static let conflictDiffWidth: CGFloat = 560
    static let expandedWidth = repositoryWidth + separatorWidth + diffWidth
    static let conflictExpandedWidth =
        repositoryWidth + separatorWidth + conflictDiffWidth

    static func metrics(
        totalWidth: CGFloat,
        preferredFraction: Double,
        minimumDetailWidth: CGFloat = minimumPaneWidth
    ) -> RepositorySplitMetrics {
        let availablePaneWidth = max(0, totalWidth - separatorWidth)
        let effectiveRepositoryMinimum = min(
            minimumPaneWidth,
            availablePaneWidth / 2
        )
        let effectiveDetailMinimum = min(
            minimumDetailWidth,
            availablePaneWidth - effectiveRepositoryMinimum
        )
        let allowedRepositoryWidths: ClosedRange<CGFloat> =
            effectiveRepositoryMinimum...(availablePaneWidth - effectiveDetailMinimum)
        let fraction = preferredFraction.isFinite
            ? min(max(CGFloat(preferredFraction), 0), 1)
            : CGFloat(defaultFraction)
        let repositoryWidth = min(
            max(availablePaneWidth * fraction, allowedRepositoryWidths.lowerBound),
            allowedRepositoryWidths.upperBound
        )

        return RepositorySplitMetrics(
            repositoryWidth: repositoryWidth,
            detailWidth: max(0, availablePaneWidth - repositoryWidth),
            availablePaneWidth: availablePaneWidth,
            allowedRepositoryWidths: allowedRepositoryWidths
        )
    }
}

struct RepositorySplitMetrics {
    let repositoryWidth: CGFloat
    let detailWidth: CGFloat
    let availablePaneWidth: CGFloat
    let allowedRepositoryWidths: ClosedRange<CGFloat>
}

struct RepositorySplitResizeHandle: View {
    @Binding var fraction: Double
    @Binding var widthAtDragStart: CGFloat?
    let currentRepositoryWidth: CGFloat
    let availablePaneWidth: CGFloat
    let allowedRepositoryWidths: ClosedRange<CGFloat>
    @State private var isHovered = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: RepositorySplitLayout.resizeHandleWidth)
            .overlay {
                Rectangle()
                    .fill(
                        isHovered || widthAtDragStart != nil
                            ? AppTheme.actionBlue
                            : AppTheme.edge
                    )
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovered {
                    NSCursor.pop()
                    isHovered = false
                }
                widthAtDragStart = nil
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if widthAtDragStart == nil {
                            widthAtDragStart = currentRepositoryWidth
                        }
                        guard let widthAtDragStart else { return }
                        setRepositoryWidth(
                            widthAtDragStart + value.translation.width
                        )
                    }
                    .onEnded { value in
                        widthAtDragStart = nil
                        // The zero-distance drag claims every click, so a
                        // separate tap gesture would never see the double-click.
                        if NSApp.currentEvent?.clickCount == 2,
                           abs(value.translation.width) < 2 {
                            setRepositoryWidth(
                                availablePaneWidth
                                    * CGFloat(RepositorySplitLayout.defaultFraction)
                            )
                        }
                    }
            )
            .accessibilityLabel("Resize repository and side panels")
            .accessibilityValue(
                "\(Int((currentRepositoryWidth / max(1, availablePaneWidth) * 100).rounded()))% repository"
            )
            .help("Drag to resize repository and side panels. Double-click to reset.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    setRepositoryWidth(currentRepositoryWidth + 24)
                case .decrement:
                    setRepositoryWidth(currentRepositoryWidth - 24)
                @unknown default:
                    break
                }
            }
    }

    private func setRepositoryWidth(_ proposedWidth: CGFloat) {
        guard availablePaneWidth > 0 else {
            fraction = RepositorySplitLayout.defaultFraction
            return
        }
        let resolvedWidth = min(
            max(proposedWidth, allowedRepositoryWidths.lowerBound),
            allowedRepositoryWidths.upperBound
        )
        fraction = Double(resolvedWidth / availablePaneWidth)
    }
}

struct DiffPanelWindowExpansion: NSViewRepresentable {
    let isExpanded: Bool
    let minimumExpandedWidth: CGFloat?
    let reduceMotion: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
            context.coordinator.update(
                isExpanded: isExpanded,
                minimumExpandedWidth: minimumExpandedWidth,
                reduceMotion: reduceMotion
            )
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window)
            context.coordinator.update(
                isExpanded: isExpanded,
                minimumExpandedWidth: minimumExpandedWidth,
                reduceMotion: reduceMotion
            )
        }
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var collapsedContentWidth: CGFloat?
        private var lastExpandedState: Bool?
        private var lastMinimumExpandedWidth: CGFloat?
        private var automaticExpandedContentWidth: CGFloat?
        private let sizing = RepositoryViewerSizing()

        func attach(to window: NSWindow?) {
            guard self.window !== window else { return }
            self.window = window
            collapsedContentWidth = nil
            lastExpandedState = nil
            lastMinimumExpandedWidth = nil
            automaticExpandedContentWidth = nil
        }

        func update(
            isExpanded: Bool,
            minimumExpandedWidth: CGFloat?,
            reduceMotion: Bool
        ) {
            guard let window else { return }

            // The conflict resolver asks for a wider panel and can appear
            // after the panel is already open (its session loads
            // asynchronously), so a raised width request must also widen an
            // expanded window. Growth only: a lowered request never shrinks
            // the window mid-session, and manual resizes are respected.
            let stateChanged = lastExpandedState != isExpanded
            let widthRequestGrew = isExpanded && !stateChanged
                && (minimumExpandedWidth ?? 0)
                    > (lastMinimumExpandedWidth ?? 0)
            lastMinimumExpandedWidth = minimumExpandedWidth
            guard stateChanged || widthRequestGrew else { return }

            if lastExpandedState == nil, !isExpanded {
                lastExpandedState = false
                return
            }

            let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
            let currentContentWidth = window.contentLayoutRect.width
            let targetContentWidth: CGFloat

            if isExpanded {
                if stateChanged {
                    collapsedContentWidth = currentContentWidth
                } else {
                    persistManualResize(currentContentWidth)
                }
                targetContentWidth = min(visibleFrame.width, sizing.targetContentWidth(
                    currentContentWidth: currentContentWidth,
                    defaultExpandedContentWidth: RepositorySplitLayout.expandedWidth,
                    minimumExpandedContentWidth: minimumExpandedWidth
                ))
                automaticExpandedContentWidth = targetContentWidth
            } else {
                if lastExpandedState == true {
                    persistManualResize(currentContentWidth)
                }
                targetContentWidth = collapsedContentWidth
                    ?? currentContentWidth
                collapsedContentWidth = nil
                automaticExpandedContentWidth = nil
            }
            lastExpandedState = isExpanded

            guard abs(targetContentWidth - currentContentWidth) > 0.5 else {
                return
            }

            let oldFrame = window.frame
            var targetFrame = window.frameRect(
                forContentRect: NSRect(
                    origin: .zero,
                    size: NSSize(
                        width: targetContentWidth,
                        height: window.contentLayoutRect.height
                    )
                )
            )
            // This transition is horizontal only. contentLayoutRect excludes
            // title-bar space, so converting its height back to a window frame
            // would otherwise make the window shorter on every open/close cycle.
            targetFrame.size.height = oldFrame.height
            // Keep the window centered as the detail panel appears or closes so
            // the added width is shared evenly between the leading and trailing
            // edges. Screen-edge clamping below still keeps the window visible.
            targetFrame.origin.x = oldFrame.midX - (targetFrame.width / 2)
            targetFrame.origin.y = oldFrame.minY

            if targetFrame.maxX > visibleFrame.maxX {
                targetFrame.origin.x -= targetFrame.maxX - visibleFrame.maxX
            }
            targetFrame.origin.x = max(targetFrame.minX, visibleFrame.minX)
            targetFrame.origin.y = min(
                max(targetFrame.minY, visibleFrame.minY),
                visibleFrame.maxY - targetFrame.height
            )

            // Let AppKit retain the existing backing surface while resizing,
            // then refresh SwiftUI once the short frame animation completes.
            window.setFrame(targetFrame, display: true, animate: !reduceMotion)
            window.contentView?.needsLayout = true
            window.contentView?.needsDisplay = true
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (reduceMotion ? 0 : 0.3)
            ) { [weak window] in
                window?.contentView?.needsLayout = true
                window?.contentView?.needsDisplay = true
                window?.contentView?.layoutSubtreeIfNeeded()
                window?.contentView?.displayIfNeeded()
            }
        }

        private func persistManualResize(_ currentContentWidth: CGFloat) {
            guard let resizedWidth = RepositoryViewerSizing.manuallyResizedWidth(
                currentContentWidth: currentContentWidth,
                automaticContentWidth: automaticExpandedContentWidth
            ) else {
                return
            }
            sizing.saveExpandedContentWidth(resizedWidth)
            automaticExpandedContentWidth = resizedWidth
        }
    }
}

struct RepositoryEditorPanel: View {
    @EnvironmentObject private var model: RepositoryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: editorSymbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(editorSymbolColor)

                Text(model.detailTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if model.conflictResolution == nil,
                   model.gitFilePreview?.isAvailable == true {
                    Picker("File detail", selection: gitFileDetailModeBinding) {
                        ForEach(GitFileDetailMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 116)
                    .accessibilityLabel("File Detail")
                }

                if model.currentDiffFilePath != nil {
                    Button {
                        model.viewCurrentDiffInFiles()
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.secondary)
                    .disabled(!model.canViewCurrentDiffInFiles)
                    .accessibilityLabel("View File in Files")
                    .help("View File in Files at First Change")
                }

                if model.workspaceMode == .fileEditor,
                   !model.isPlainFolder,
                   model.selectedRepositoryFilePath != nil {
                    Button {
                        model.showChangesForCurrentFile()
                    } label: {
                        BranchGlyph(size: 12, color: AppTheme.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.secondary)
                    .disabled(!model.canShowChangesForCurrentFile)
                    .accessibilityLabel("Show Changes for This File")
                    .help("Show Changes for This File in Git")
                }

                if model.detailKind == .source {
                    if model.isRepositoryFileDirty {
                        Circle()
                            .fill(AppTheme.primary)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("Unsaved changes")
                    }

                    Button {
                        Task { await model.saveRepositoryFile() }
                    } label: {
                        Image(systemName: "externaldrive.badge.checkmark")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.secondary)
                    .disabled(!model.canSaveRepositoryFile)
                    .accessibilityLabel("Save File")
                    .help("Save File (⌘S)")
                }

                Button {
                    closeEditorOrReturnToSearch()
                } label: {
                    Image(
                        systemName: model.isFileSearchPresented
                            ? "chevron.backward"
                            : "xmark"
                    )
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.secondary)
                .disabled(model.isSavingRepositoryFile)
                .accessibilityLabel(editorCloseLabel)
                .help("\(editorCloseLabel) (⎋)")
            }
            .padding(.leading, 10)
            .frame(height: 36)
            .background(AppTheme.raisedFill)

            Rectangle()
                .fill(AppTheme.edge)
                .frame(height: 1)

            if model.detailKind == .source {
                if let conflictDocument = openFileConflictDocument {
                    conflictEditorNotice(for: conflictDocument)

                    Rectangle()
                        .fill(AppTheme.edge)
                        .frame(height: 1)
                }

                SourceDocument(
                    text: Binding(
                        get: { model.repositoryFileText },
                        set: { model.updateRepositoryFileTextFromEditor($0) }
                    ),
                    scrollRequest: model.repositoryFileScrollRequest,
                    isEditable: !model.isBusy && !model.isSavingRepositoryFile
                        && !model.isDetailLoading
                ) {
                    Task { await model.saveRepositoryFile() }
                } onExit: {
                    closeEditorOrReturnToSearch()
                }
                .overlay {
                    if model.isDetailLoading {
                        HStack(spacing: 9) {
                            ProgressView()
                                .controlSize(.small)
                            Text(model.detailText)
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AppTheme.diffCanvas)
                    }
                }
            } else if model.detailKind == .largeSource {
                LargeSourceDocument(
                    text: model.repositoryFileText,
                    scrollRequest: model.repositoryFileScrollRequest
                )
                .equatable()
            } else if model.isDetailLoading {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.detailText)
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.diffCanvas)
            } else if let conflictResolution = model.conflictResolution {
                ConflictResolverView(session: conflictResolution)
            } else if model.detailKind == .diff,
                      let preview = model.gitFilePreview,
                      model.gitFileDetailMode == .preview || preview.isImage {
                GitFileComparisonPreview(
                    preview: preview,
                    showsLatestOnly: preview.isImage && model.gitFileDetailMode == .preview
                )
            } else if model.detailKind == .diff {
                DiffDocument(text: model.detailText, documentID: model.detailDocumentID)
                    .equatable()
            } else if model.detailKind == .preview,
                      let url = model.selectedRepositoryFileURL {
                RepositoryFilePreview(url: url)
                    .padding(RepositoryFileLoader.isImage(at: url) ? 20 : 0)
                    .background(AppTheme.diffCanvas)
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 22))
                        .foregroundStyle(AppTheme.muted)

                    Text(model.detailText)
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.diffCanvas)
            }
        }
        .background(AppTheme.diffCanvas)
    }

    private func closeEditorOrReturnToSearch() {
        if model.isFileSearchPresented {
            model.showRepositorySearchResults()
        } else {
            model.closeEditorPanel()
        }
    }

    private var editorCloseLabel: String {
        model.isFileSearchPresented
            ? "Return to Search Results"
            : "Close \(editorName)"
    }

    private var openFileConflictDocument: ConflictDocument? {
        guard model.detailKind == .source,
              let path = model.selectedRepositoryFilePath else { return nil }
        return ConflictDocument.parse(path: path, text: model.repositoryFileText)
    }

    private func conflictEditorNotice(for document: ConflictDocument) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.conflict)

            Text("\(document.hunks.count) unresolved \(document.hunks.count == 1 ? "conflict" : "conflicts")")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(AppTheme.primary)

            // Swatches instead of color names: imported themes repaint the
            // side hues, so naming them here could lie.
            conflictLegendItem(color: AppTheme.graphBlue, label: "Current")
            conflictLegendItem(color: AppTheme.added, label: "Incoming")

            Spacer(minLength: 8)

            if model.canShowChangesForCurrentFile {
                Button("Open Resolver") {
                    model.showChangesForCurrentFile()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AppTheme.graphBlue)
                .accessibilityHint("Opens the hunk-by-hunk conflict resolver")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(AppTheme.conflict.opacity(0.07))
    }

    private func conflictLegendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)

            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(AppTheme.muted)
        }
        .lineLimit(1)
    }

    private var editorSymbol: String {
        if model.conflictResolution != nil { return "arrow.triangle.branch" }
        guard model.detailKind != .diff || model.gitFileDetailMode == .preview else {
            return "doc.text"
        }
        return FileGlyph.symbol(forPath: model.detailTitle)
    }

    private var editorSymbolColor: Color {
        FileGlyph.color(forSymbol: editorSymbol)
    }

    private var editorName: String {
        if model.conflictResolution != nil { return "Conflict Resolver" }
        if model.detailKind == .diff {
            return model.gitFileDetailMode == .preview ? "Preview" : "Diff"
        }
        return "File"
    }

    private var gitFileDetailModeBinding: Binding<GitFileDetailMode> {
        Binding(
            get: { model.gitFileDetailMode },
            set: { model.setGitFileDetailMode($0) }
        )
    }
}

struct GitFileComparisonPreview: View {
    let preview: GitFilePreview
    var showsLatestOnly = false
    @State private var scrollSynchronizer = QuickLookPreviewScrollSynchronizer()

    var body: some View {
        HStack(spacing: 0) {
            if let old = preview.old, !showsLatestOnly || preview.new == nil {
                versionPane(old)
            }

            if preview.old != nil, preview.new != nil, !showsLatestOnly {
                Rectangle()
                    .fill(AppTheme.edge)
                    .frame(width: 1)
            }

            if let new = preview.new {
                versionPane(new)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.diffCanvas)
    }

    private func versionPane(_ version: GitFilePreviewVersion) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Text(version.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.primary)

                Text(version.context)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(AppTheme.raisedFill)

            Rectangle()
                .fill(AppTheme.edge)
                .frame(height: 1)

            RepositoryFilePreview(
                url: version.url,
                scrollSynchronizer: scrollSynchronizer
            )
                .padding(RepositoryFileLoader.isImage(at: version.url) ? 20 : 0)
                .background(AppTheme.diffCanvas)
                .accessibilityLabel("\(version.title) file preview, \(version.context)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import AppKit
import SwiftUI

struct ChangesPanel: View {
    @EnvironmentObject private var model: RepositoryModel
    let isOpeningRepository: Bool

    var body: some View {
        VStack(spacing: 0) {
            ChangesActionBar()

            if isOpeningRepository || isModelOpeningRepository {
                ChangesPanelLoadingContent()
            } else {
                if let operation = model.activeOperation {
                    ConflictResolutionGuide(operation: operation)
                        .padding(.horizontal, 30)
                        .padding(.top, 2)
                        .padding(.bottom, 8)
                } else {
                    VStack(spacing: 10) {
                        CommitMessageField()
                        SplitCommitButton()
                    }
                    .padding(.horizontal, 30)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                }

                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if !model.staged.isEmpty {
                            FileSection(
                                title: "Staged Changes",
                                changes: model.staged,
                                expanded: $model.isStagedSectionExpanded,
                                action: { Task { await model.unstageAll() } }
                            )
                        }

                        FileSection(
                            title: "Changes",
                            changes: model.unstaged,
                            expanded: $model.isUnstagedSectionExpanded,
                            action: { Task { await model.stageAll() } }
                        )

                        if model.staged.isEmpty && model.unstaged.isEmpty {
                            Text("No changes. The working tree is clean.")
                                .font(AppType.rowDetail)
                                .foregroundStyle(AppTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 31)
                                .padding(.top, 8)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                // Every tab shares this view. A new identity per model resets
                // the sections' paging state instead of carrying it over.
                .id(ObjectIdentifier(model))
            }
        }
    }

    private var isModelOpeningRepository: Bool {
        model.repositoryURL == nil && model.isBusy
    }
}

struct ConflictResolutionGuide: View {
    @EnvironmentObject private var model: RepositoryModel
    let operation: GitOperation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: unresolvedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.primary)
            }

            Text(instructions)
                .font(AppType.rowDetail)
                .foregroundStyle(AppTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Abort \(operation.displayName)…", role: .destructive) {
                    Task { await model.abortActiveOperation() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.deleted)

                Spacer(minLength: 8)

                Button(primaryActionTitle) {
                    if model.hasUnresolvedConflicts {
                        model.openNextConflict()
                    } else {
                        Task { await model.continueActiveOperation() }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.onAccent)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    AppTheme.actionBlue,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .help(primaryActionHelp)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(AppTheme.inputFill)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(statusColor.opacity(0.55), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }

    private var unresolvedCount: Int {
        model.unresolvedConflicts.count
    }

    private var title: String {
        if unresolvedCount == 0 { return "\(operation.displayName) ready to continue" }
        return unresolvedCount == 1
            ? "Resolve 1 conflict"
            : "Resolve \(unresolvedCount) conflicts"
    }

    private var instructions: String {
        if unresolvedCount == 0 {
            return operation == .merge
                ? "All conflicts are staged. Continue to create the merge commit."
                : "All conflicts are staged. Continue replaying commits onto the target branch."
        }
        return "Open a conflicted file, choose a result for each hunk, then mark it resolved."
    }

    private var statusColor: Color {
        unresolvedCount == 0 ? AppTheme.added : AppTheme.conflict
    }

    private var primaryActionTitle: String {
        model.hasUnresolvedConflicts
            ? "Resolve Next Conflict"
            : "Continue \(operation.displayName)"
    }

    private var primaryActionHelp: String {
        if model.hasUnresolvedConflicts { return "Open the next conflicted file" }
        return operation == .merge ? "Create the merge commit" : "Continue the operation"
    }
}

struct ChangesPanelLoadingContent: View {
    private let rowWidths: [CGFloat] = [132, 184, 106, 156]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                LoadingFieldPlaceholder()

                LoadingPlaceholder(width: nil, height: 32, cornerRadius: 6)
            }
            .padding(.horizontal, 30)
            .padding(.top, 2)
            .padding(.bottom, 8)

            HStack(spacing: 8) {
                LoadingPlaceholder(width: 82, height: 13, cornerRadius: 3)
                LoadingPlaceholder(width: 22, height: 17, cornerRadius: 8.5)
                Spacer()
            }
            .padding(.horizontal, 31)
            .frame(height: 33)

            ForEach(Array(rowWidths.enumerated()), id: \.offset) { index, width in
                HStack(spacing: 9) {
                    LoadingPlaceholder(width: 17, height: 17, cornerRadius: 3)

                    VStack(alignment: .leading, spacing: 4) {
                        LoadingPlaceholder(width: width, height: 10, cornerRadius: 3)
                        LoadingPlaceholder(
                            width: max(54, width * 0.58),
                            height: 7,
                            cornerRadius: 2.5
                        )
                    }

                    Spacer(minLength: 8)

                    LoadingPlaceholder(
                        width: index == 1 ? 18 : 12,
                        height: 10,
                        cornerRadius: 3
                    )
                }
                .padding(.horizontal, 31)
                .frame(height: 32)
            }

            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }
}

struct LoadingFieldPlaceholder: View {
    var body: some View {
        HStack {
            LoadingPlaceholder(width: 146, height: 10, cornerRadius: 3)
            Spacer()
            LoadingPlaceholder(width: 17, height: 17, cornerRadius: 5)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(AppTheme.inputFill)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(AppTheme.inputBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct LoadingPlaceholder: View {
    let width: CGFloat?
    let height: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(AppTheme.secondary.opacity(0.13))
            .frame(maxWidth: width == nil ? .infinity : nil)
            .frame(width: width, height: height)
    }
}

struct ChangesActionBar: View {
    @EnvironmentObject private var model: RepositoryModel

    var body: some View {
        HStack(spacing: 0) {
            RepositoryModePicker()

            Spacer()

            if model.sshRepository != nil {
                RepositoryReloadButton()
                    .padding(.trailing, 4)
            }

            RepositoryTerminalButton()

            RepositoryLocationMenu()
                .padding(.leading, 4)
        }
        .padding(.leading, 22)
        .padding(.trailing, 22)
        .frame(maxWidth: .infinity)
        // Tall enough to give the 30pt mode picker capsule clear air above
        // and below, matching Xcode's navigator-switcher bar.
        .frame(height: 46)
        // With window-server dragging disabled (`isMovable = false`), give
        // the empty areas of this bar back to window dragging.
        .background(WindowDragHandle())
    }
}

/// Background view whose empty areas drag the window. Needed because
/// AppKit-initiated window dragging is disabled (`NSWindow.isMovable` is
/// false, see `WindowConfigurator`), so any region that should move the
/// window must call `performDrag` explicitly.
struct WindowDragHandle: NSViewRepresentable {
    final class HandleView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView {
        HandleView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct SpinningCodiconGlyph: View {
    let icon: Codicon
    let isSpinning: Bool
    var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isSpinning && !reduceMotion {
            RotatingCodiconGlyph(icon: icon, size: size)
        } else {
            CodiconGlyph(icon: icon, size: size)
        }
    }
}

struct RotatingCodiconGlyph: View {
    let icon: Codicon
    let size: CGFloat
    @State private var rotating = false

    var body: some View {
        CodiconGlyph(icon: icon, size: size)
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotating = true
                }
            }
    }
}

struct CodiconButton: View {
    let icon: Codicon
    let help: String
    var size: CGFloat = 16
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CodiconGlyph(icon: icon, size: size)
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.primary)
        .accessibilityLabel(help)
        .help(help)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 15
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.primary)
        .accessibilityLabel(help)
        .help(help)
    }
}

struct CommitMessageField: View {
    @EnvironmentObject private var model: RepositoryModel

    var body: some View {
        CommitMessageInput(
            model: model,
            messageState: model.commitMessageState
        )
    }
}

struct CommitMessageInput: View {
    @ObservedObject var model: RepositoryModel
    @ObservedObject var messageState: CommitMessageState
    @AppStorage(AICommitMessagePreferences.providerKey)
    private var aiProviderRawValue = AICommitMessageProvider.codex.rawValue
    @FocusState private var focused: Bool

    private var aiProvider: AICommitMessageProvider {
        AICommitMessageProvider(rawValue: aiProviderRawValue) ?? .codex
    }

    private var commitPlaceholder: String {
        let branch = model.branch
        guard !branch.isEmpty, branch != "detached HEAD" else {
            return "Message (⌘Return to commit)"
        }
        return "Message (⌘Return to commit on \(branch))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack(alignment: .leading) {
                if messageState.text.isEmpty {
                    Text(commitPlaceholder)
                        .font(AppType.row)
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }

                TextField("", text: $messageState.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(AppType.row)
                    .foregroundStyle(AppTheme.primary)
                    .accessibilityLabel("Commit message")
                    .focused($focused)
                    .lineLimit(1...10)
                    .fixedSize(horizontal: false, vertical: true)
                    .disabled(
                        model.isBusy
                            || model.isSavingRepositoryFile
                            || model.hasPendingChangeOperations
                    )
            }

            Button {
                if model.isGeneratingCommitMessage {
                    model.cancelCommitMessageGeneration()
                } else {
                    Task { await model.generateCommitMessage() }
                }
            } label: {
                Group {
                    if model.isGeneratingCommitMessage {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .medium))
                    }
                }
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.primary.opacity(0.9))
            .padding(.top, 1)
            .accessibilityLabel(
                model.isGeneratingCommitMessage
                    ? "Stop Generating Commit Message"
                    : "Generate Commit Message from Staged Changes"
            )
            .help(
                model.isGeneratingCommitMessage
                    ? "Stop Generating"
                    : model.hasStagedChanges
                    ? (messageState.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Generate a Commit Message from Staged Changes with \(aiProvider.displayName)"
                        : "Use This Text as Instructions for \(aiProvider.displayName)")
                    : "Stage changes before generating a commit message"
            )
            .disabled(
                !model.isGeneratingCommitMessage
                    && (!model.hasStagedChanges
                        || model.isBusy
                        || model.isSavingRepositoryFile
                        || model.hasPendingChangeOperations)
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 34)
        .background(AppTheme.inputFill)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    focused ? AppTheme.graphBlue : AppTheme.inputBorder,
                    lineWidth: focused ? 1.5 : 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct SplitCommitButton: View {
    @EnvironmentObject private var model: RepositoryModel

    var body: some View {
        HStack(spacing: 0) {
            Button {
                Task { await model.performPrimaryAction() }
            } label: {
                HStack(spacing: 7) {
                    SpinningCodiconGlyph(
                        icon: primaryActionIcon,
                        isSpinning: model.isSyncing && model.primaryAction == .sync,
                        size: 15
                    )
                    Text(model.primaryActionTitle)
                        .font(.system(size: 14, weight: .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(buttonBackground)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .disabled(!model.primaryActionEnabled)

            Menu {
                Button("Commit Staged Changes") {
                    Task { await model.commit() }
                }
                .disabled(!model.hasStagedChanges)

                Button("Commit All Changes") {
                    Task { await model.commitAll() }
                }
                .disabled(!model.hasChanges)

                Divider()

                Button("Amend Last Commit") {
                    Task { await model.amend() }
                }
                .disabled(model.headHash == nil)

                Button("Amend Last Commit, Keep Message") {
                    Task { await model.amendNoEdit() }
                }
                .disabled(!model.hasStagedChanges || model.headHash == nil)

                if model.isAmendingCommit {
                    Button("Cancel Amend") {
                        model.cancelAmend()
                    }
                }

                Divider()

                Button(commitAndRemoteTitle) {
                    Task { await commitAndRemote() }
                }
                .disabled(!model.hasChanges)

                if let operation = model.activeOperation {
                    Divider()

                    Button("Continue \(operation.displayName)") {
                        Task { await model.continueActiveOperation() }
                    }

                    if model.canSkipActiveOperation {
                        Button("Skip Current Commit") {
                            Task { await model.skipActiveOperation() }
                        }
                    }

                    Button("Abort \(operation.displayName)…", role: .destructive) {
                        Task { await model.abortActiveOperation() }
                    }
                }

                if model.primaryAction == .sync {
                    Divider()

                    Button("Push") {
                        Task { await model.push() }
                    }

                    Button("Pull") {
                        Task { await model.pull() }
                    }

                    Divider()

                    Button("Force Push with Lease…") {
                        Task { await model.forcePushWithLease() }
                    }

                    Button("Force Push Without Lease…") {
                        Task { await model.forcePush() }
                    }
                }
            } label: {
                ZStack {
                    Rectangle()
                        .fill(buttonBackground)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(menuForeground)
                }
                .frame(width: Self.menuWidth, height: 32)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .tint(menuForeground)
            .frame(width: Self.menuWidth, height: 32)
            .background(buttonBackground)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(buttonForeground.opacity(0.32))
                    .frame(width: 1)
                    .padding(.vertical, 5)
            }
            .contentShape(Rectangle())
            .help(actionMenuLabel)
            .accessibilityLabel(actionMenuLabel)
        }
        .foregroundStyle(buttonForeground)
        .frame(height: 32)
        .background(buttonBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .disabled(actionsDisabled)
    }

    private static let menuWidth: CGFloat = 38

    private var buttonBackground: Color {
        model.primaryActionEnabled
            ? AppTheme.actionBlue
            : AppTheme.disabledFill
    }

    private var buttonForeground: Color {
        model.primaryActionEnabled
            ? AppTheme.onAccent
            : AppTheme.muted
    }

    /// The menu can offer Amend even when the primary action has nothing to
    /// do, so its chevron follows its own availability.
    private var menuForeground: Color {
        if actionsDisabled { return AppTheme.muted }
        return model.primaryActionEnabled ? AppTheme.onAccent : AppTheme.primary
    }

    private var actionMenuLabel: String {
        model.primaryAction == .sync ? "Sync Actions" : "Commit Actions"
    }

    private var actionsDisabled: Bool {
        model.isBusy
            || model.isSavingRepositoryFile
            || model.isGeneratingCommitMessage
            || model.hasPendingChangeOperations
    }

    private var primaryActionIcon: Codicon {
        switch model.primaryAction {
        case .commit: return .check
        case .publish: return .repoPush
        case .sync: return .sync
        }
    }

    private var commitAndRemoteTitle: String {
        if !model.hasUpstream { return "Commit and Publish Branch" }
        if model.behind > 0 { return "Commit, then Sync" }
        return "Commit and Push"
    }

    private func commitAndRemote() async {
        if model.hasUpstream && model.behind > 0 {
            await model.commitAndSync()
        } else {
            await model.commitAndPush()
        }
    }
}

struct FileSection: View {
    @EnvironmentObject private var model: RepositoryModel
    let title: String
    let changes: [FileChange]
    @Binding var expanded: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var selectedGroupID: String?
    @State private var filePage = 0
    @State private var groupPage = 0

    private let directFileLimit = 250
    private let filesPerPage = 200
    private let groupsPerPage = 100

    var body: some View {
        Section {
            if expanded {
                if changes.count <= directFileLimit {
                    ForEach(changes) { change in
                        FileChangeRow(change: change)
                    }
                } else {
                    largeChangesContent
                }
            }
        } header: {
            HStack(spacing: 9) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 0) {
                        Text(title)
                            .font(AppType.sectionTitle)

                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(expanded ? "Collapse" : "Expand") \(title)"
                )

                if !changes.isEmpty {
                    if title == "Changes" {
                        IconButton(
                            symbol: "arrow.uturn.backward",
                            help: "Discard All Unstaged Changes",
                            size: 13
                        ) {
                            guard GitPrompt.confirmDiscardAllUnstagedChanges() else { return }
                            Task { await model.discardAllUnstagedChanges() }
                        }
                        .disabled(actionsDisabled || model.hasUnresolvedConflicts)
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                    }

                    IconButton(
                        symbol: title == "Changes" ? "plus" : "minus",
                        help: title == "Changes"
                            ? "Stage All Changes"
                            : "Unstage All Changes",
                        size: 13,
                        action: action
                    )
                    .disabled(
                        actionsDisabled
                    )
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)

                    Text("\(changes.count)")
                        .font(AppType.captionEmphasis)
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.badgeText)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(AppTheme.badgeBlue, in: Capsule())
                        .help(
                            "\(changes.count) \(title == "Changes" ? "unstaged" : "staged") "
                                + (changes.count == 1 ? "change" : "changes")
                        )
                }
            }
            .padding(.leading, 22)
            .padding(.trailing, 21)
            .frame(height: 33)
            .contentShape(Rectangle())
            .foregroundStyle(AppTheme.primary)
            .background(hovering ? AppTheme.hover : AppTheme.canvas)
            .onHover { hovering = $0 }
            .contextMenu {
                Button(title == "Changes" ? "Stage All" : "Unstage All", action: action)
                    .disabled(changes.isEmpty || actionsDisabled)

                if title == "Changes" {
                    Divider()

                    Button("Stash Changes…") {
                        guard let stash = GitPrompt.stash() else { return }
                        Task {
                            await model.stashChanges(
                                message: stash.message,
                                includeUntracked: stash.includeUntracked
                            )
                        }
                    }
                    .disabled(!model.hasChanges || actionsDisabled)

                    Button("Discard All Changes…", role: .destructive) {
                        guard GitPrompt.confirmDiscardAllChanges() else { return }
                        Task { await model.discardAllChanges() }
                    }
                    .disabled(!model.hasChanges || model.headHash == nil || actionsDisabled)
                }
            }
            .accessibilityActions {
                Button(title == "Changes" ? "Stage All Changes" : "Unstage All Changes") {
                    guard !changes.isEmpty, !actionsDisabled else { return }
                    action()
                }

                if title == "Changes" {
                    Button("Discard All Unstaged Changes") {
                        guard !changes.isEmpty,
                              !actionsDisabled,
                              !model.hasUnresolvedConflicts,
                              GitPrompt.confirmDiscardAllUnstagedChanges() else { return }
                        Task { await model.discardAllUnstagedChanges() }
                    }
                }
            }
            .onChange(of: changes) {
                normalizePagination()
            }
        }
    }

    @ViewBuilder
    private var largeChangesContent: some View {
        let groups = changeGroups
        if let selectedGroup = groups.first(where: { $0.id == selectedGroupID }) {
            LargeChangeGroupHeader(
                group: selectedGroup,
                page: filePage,
                pageCount: pageCount(selectedGroup.changes.count, size: filesPerPage),
                back: {
                    selectedGroupID = nil
                    filePage = 0
                },
                previous: { filePage = max(0, filePage - 1) },
                next: {
                    filePage = min(
                        pageCount(selectedGroup.changes.count, size: filesPerPage) - 1,
                        filePage + 1
                    )
                }
            )

            ForEach(fileSlice(for: selectedGroup)) { change in
                FileChangeRow(change: change)
            }
        } else {
            ForEach(groupSlice(from: groups)) { group in
                Button {
                    selectedGroupID = group.id
                    filePage = 0
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "folder")
                            .font(.system(size: 13))
                            .foregroundStyle(AppTheme.secondary)
                            .frame(width: 20)

                        Text(group.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppTheme.primary)
                            .lineLimit(1)

                        Spacer()

                        Text("\(group.changes.count)")
                            .font(AppType.captionEmphasis)
                            .foregroundStyle(AppTheme.secondary)
                    }
                    .padding(.horizontal, 28)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(group.title)
            }

            if groups.count > groupsPerPage {
                ChangePaginationRow(
                    page: groupPage,
                    pageCount: pageCount(groups.count, size: groupsPerPage),
                    label: "folders",
                    previous: { groupPage = max(0, groupPage - 1) },
                    next: {
                        groupPage = min(
                            pageCount(groups.count, size: groupsPerPage) - 1,
                            groupPage + 1
                        )
                    }
                )
            }
        }
    }

    private var changeGroups: [FileChangeGroup] {
        let grouped = Dictionary(grouping: changes) { change -> String in
            let components = change.path.split(separator: "/", maxSplits: 1)
            return components.count > 1 ? String(components[0]) : ""
        }
        return grouped.map { key, values in
            FileChangeGroup(
                id: key,
                title: key.isEmpty ? "Repository root" : key,
                changes: values
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func groupSlice(from groups: [FileChangeGroup]) -> ArraySlice<FileChangeGroup> {
        let start = min(groupPage * groupsPerPage, groups.count)
        let end = min(start + groupsPerPage, groups.count)
        return groups[start..<end]
    }

    private func fileSlice(for group: FileChangeGroup) -> ArraySlice<FileChange> {
        let start = min(filePage * filesPerPage, group.changes.count)
        let end = min(start + filesPerPage, group.changes.count)
        return group.changes[start..<end]
    }

    private func pageCount(_ count: Int, size: Int) -> Int {
        max(1, Int(ceil(Double(count) / Double(size))))
    }

    private var actionsDisabled: Bool {
        model.isBusy
            || model.hasPendingChangeOperations
            || model.isGeneratingCommitMessage
    }

    private func normalizePagination() {
        let groups = changeGroups
        groupPage = min(
            groupPage,
            pageCount(groups.count, size: groupsPerPage) - 1
        )

        guard let selectedGroupID,
              let selectedGroup = groups.first(where: { $0.id == selectedGroupID }) else {
            self.selectedGroupID = nil
            filePage = 0
            return
        }

        filePage = min(
            filePage,
            pageCount(selectedGroup.changes.count, size: filesPerPage) - 1
        )
    }
}

struct FileChangeGroup: Identifiable {
    let id: String
    let title: String
    let changes: [FileChange]
}

struct LargeChangeGroupHeader: View {
    let group: FileChangeGroup
    let page: Int
    let pageCount: Int
    let back: () -> Void
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to change folders")
            .help("Back to Change Folders")

            Text(group.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Text("\(group.changes.count) files")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.secondary)

            Spacer()

            if pageCount > 1 {
                PaginationButtons(page: page, pageCount: pageCount, previous: previous, next: next)
            }
        }
        .padding(.horizontal, 23)
        .frame(height: 32)
        .background(AppTheme.inputFill)
    }
}

struct ChangePaginationRow: View {
    let page: Int
    let pageCount: Int
    let label: String
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
        HStack {
            Text("Page \(page + 1) of \(pageCount) \(label)")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.secondary)
            Spacer()
            PaginationButtons(page: page, pageCount: pageCount, previous: previous, next: next)
        }
        .padding(.horizontal, 28)
        .frame(height: 32)
    }
}

struct PaginationButtons: View {
    let page: Int
    let pageCount: Int
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: previous) {
                Image(systemName: "chevron.left").frame(width: 22, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(page == 0)
            .accessibilityLabel("Previous page")
            .help("Previous Page")

            Text("\(page + 1)/\(pageCount)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AppTheme.secondary)

            Button(action: next) {
                Image(systemName: "chevron.right").frame(width: 22, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(page + 1 >= pageCount)
            .accessibilityLabel("Next page")
            .help("Next Page")
        }
    }
}

struct FileChangeRow: View {
    @EnvironmentObject private var model: RepositoryModel
    let change: FileChange
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.activate(change)
            } label: {
                HStack(spacing: 8) {
                    FileIconView(path: change.path, size: 14, width: 21)

                    HStack(spacing: 8) {
                        Text(change.name)
                            .font(AppType.row)
                            .foregroundStyle(AppTheme.primary)
                            .lineLimit(1)
                            .layoutPriority(1)

                        if !change.parentPath.isEmpty {
                            Text(change.parentPath)
                                .font(AppType.rowDetail)
                                .foregroundStyle(AppTheme.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(change.path)

            if model.isChangeOperationPending(change) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(AppTheme.secondary)
                    .frame(width: 18)
                    .accessibilityLabel("Updating \(change.name)")
            } else if isReopenableConflict {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.conflict)
                    .frame(width: 18, alignment: .trailing)
                    .accessibilityLabel(statusDescription)
                    .help(statusDescription)
            } else {
                Text(change.status)
                    .font(AppType.statusLetter)
                    .foregroundStyle(statusColor)
                    .frame(width: 18, alignment: .trailing)
                    .accessibilityLabel(statusDescription)
                    .help(statusDescription)
            }
        }
        .padding(.leading, 28)
        .padding(.trailing, 23)
        .frame(height: 31)
        .contentShape(Rectangle())
        .background(
            model.selectedChange == change
                ? AppTheme.selection
                : (hovering ? AppTheme.hover : .clear)
        )
        // The hover actions float above the label instead of sitting in the
        // HStack, so they never steal width from the filename; the text fades
        // out beneath them behind a scrim.
        .overlay(alignment: .trailing) {
            hoverActions
        }
        .onHover { hovering = $0 }
        .contextMenu {
            if isResolvableConflict {
                Button("Resolve Conflict") {
                    model.select(change)
                }
                .disabled(operationDisabled)
            } else {
                if isReopenableConflict {
                    Button("Reopen Conflict") {
                        Task { await model.reopenConflict(change) }
                    }
                    .disabled(operationDisabled)

                    Divider()
                }

                if change.area == .unstaged {
                    Button(change.status == "U" ? "Delete…" : "Discard Changes…") {
                        confirmDiscard()
                    }
                    .disabled(operationDisabled)

                    Divider()
                }

                if change.area == .unstaged || !isReopenableConflict {
                    Button(change.area == .staged ? "Unstage" : "Stage") {
                        performStageToggle()
                    }
                    .disabled(operationDisabled)
                }
            }

            Divider()

            Button("Open in Files") {
                model.openInFiles(change)
            }
            .disabled(!model.canOpenInFiles(change))

            if model.sshRepository == nil {
                Button("Reveal in Finder") {
                    revealRepositoryFileInFinder(change.path, repositoryURL: model.repositoryURL)
                }
            }

            Button("Copy Path") {
                copyRepositoryFilePath(change.path, in: model)
            }
        }
        .accessibilityActions {
            if isResolvableConflict {
                Button("Resolve Conflict in \(change.name)") {
                    model.select(change)
                }
                .disabled(operationDisabled)
            } else {
                if isReopenableConflict {
                    Button("Reopen conflict in \(change.name)") {
                        Task { await model.reopenConflict(change) }
                    }
                    .disabled(operationDisabled)
                }

                if change.area == .unstaged || !isReopenableConflict {
                    Button(change.area == .staged ? "Unstage \(change.name)" : "Stage \(change.name)") {
                        performStageToggle()
                    }
                    .disabled(operationDisabled)
                }
            }

            if change.status != "D" {
                Button("Open \(change.name) in Files") {
                    model.openInFiles(change)
                }
            }

            if change.area == .unstaged && !isResolvableConflict {
                Button("Discard Changes in \(change.name)") {
                    confirmDiscard()
                }
                .disabled(operationDisabled)
            }
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 8) {
            if change.status != "D" {
                Button {
                    model.openInFiles(change)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 31)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(change.name) in Files")
                .help("Open in Files")
            }

            if isResolvableConflict {
                Button {
                    model.select(change)
                } label: {
                    Text("Resolve")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(height: 31)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .disabled(operationDisabled)
                .accessibilityLabel("Resolve conflict in \(change.name)")
                .help("Resolve Conflict")
            } else if isReopenableConflict {
                Button {
                    Task { await model.reopenConflict(change) }
                } label: {
                    Text("Reopen")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(height: 31)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .disabled(operationDisabled)
                .accessibilityLabel("Reopen conflict in \(change.name)")
                .help("Restore the conflict versions and reopen the resolver")
            } else if change.area == .unstaged {
                Button {
                    confirmDiscard()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 31)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Discard Changes in \(change.name)")
                .help("Discard Changes")
                .disabled(operationDisabled)
            }

            if !isResolvableConflict && (change.area == .unstaged || !isReopenableConflict) {
                Button {
                    performStageToggle()
                } label: {
                    Image(systemName: change.area == .staged ? "minus" : "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 31)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    change.area == .staged ? "Unstage \(change.name)" : "Stage \(change.name)"
                )
                .help(change.area == .staged ? "Unstage" : "Stage")
                .disabled(operationDisabled)
            }
        }
        .foregroundStyle(AppTheme.primary)
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .background(hoverActionScrim)
        // Stop short of the status letter (23pt row inset + its 18pt slot)
        // so it stays visible beside the actions.
        .padding(.trailing, 41)
        .opacity(hovering ? 1 : 0)
        .allowsHitTesting(hovering)
        .accessibilityHidden(!hovering)
    }

    /// Opaque backdrop for the floating actions with a soft leading fade.
    /// Canvas sits underneath because the selection tint is translucent and
    /// would otherwise let the covered text bleed through.
    private var hoverActionScrim: some View {
        ZStack {
            AppTheme.canvas

            if model.selectedChange == change {
                AppTheme.selection
            } else {
                AppTheme.hover
            }
        }
        .mask(
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 20)

                Rectangle()
            }
        )
    }

    private func confirmDiscard() {
        let result = AppDialog.run(
            title: discardConfirmationTitle,
            message: discardConfirmationMessage,
            actions: [
                AppDialogAction(title: "Cancel", role: .cancel),
                AppDialogAction(title: discardConfirmationAction, role: .destructive)
            ]
        )
        guard result.actionIndex == 1 else { return }
        Task { await model.discard(change) }
    }

    private var discardConfirmationTitle: String {
        change.status == "U" ? "Delete Untracked File?" : "Discard Changes?"
    }

    private var discardConfirmationAction: String {
        change.status == "U" ? "Delete" : "Discard Changes"
    }

    private var discardConfirmationMessage: String {
        if change.status == "U" {
            return "Delete \"\(change.path)\" from disk. This action cannot be undone by Kvist."
        }
        return "Discard all unstaged changes in \"\(change.path)\". This action cannot be undone by Kvist."
    }


    private var statusColor: Color {
        switch change.status {
        case "A", "U": return AppTheme.added
        case "D": return AppTheme.deleted
        case "R", "C": return AppTheme.graphBlue
        case "!": return AppTheme.conflict
        default: return AppTheme.modified
        }
    }

    private var statusDescription: String {
        if isReopenableConflict {
            return "Conflict resolution was unstaged; the conflict can be reopened"
        }
        switch change.status {
        case "A": return "Added"
        case "U": return "Untracked"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "!": return "Conflict"
        default: return "Modified"
        }
    }

    private var operationDisabled: Bool {
        model.isBusy
            || model.isGeneratingCommitMessage
            || model.isChangeOperationPending(change)
    }

    private var isResolvableConflict: Bool {
        model.activeOperation != nil
            && change.area == .unstaged
            && change.status == "!"
    }

    private var isReopenableConflict: Bool {
        model.isReopenableConflict(change)
    }

    private func performStageToggle() {
        guard !operationDisabled else { return }
        Task {
            if change.area == .staged {
                await model.unstage(change)
            } else {
                await model.stage(change)
            }
        }
    }
}

import AppKit
import SwiftUI

struct ConflictResolverView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var model: RepositoryModel
    let session: ConflictResolutionSession
    @State private var navigationCursor: Int?

    var body: some View {
        if let document = session.document {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    resolverToolbar(document: document, proxy: proxy)

                    Rectangle()
                        .fill(AppTheme.edge)
                        .frame(height: 1)

                    ScrollView {
                        // A plain VStack keeps every hunk view alive so an
                        // in-progress custom edit survives scrolling away.
                        VStack(spacing: 0) {
                            ForEach(Array(document.hunks.enumerated()), id: \.element.id) { index, hunk in
                                ConflictHunkView(
                                    number: index + 1,
                                    hunk: hunk,
                                    contextBefore: document.contextBefore(hunkID: hunk.id),
                                    contextAfter: document.contextAfter(hunkID: hunk.id),
                                    currentTitle: session.currentTitle,
                                    incomingTitle: session.incomingTitle,
                                    choice: session.choices[hunk.id],
                                    choose: { choice in
                                        model.chooseConflictHunk(hunk.id, choice: choice)
                                    }
                                )
                                .id(hunk.id)
                            }
                        }
                    }
                    .scrollIndicators(.visible)
                }
                .background(AppTheme.diffCanvas)
                // Reset scroll position, navigation cursor, and editor drafts
                // when the resolver moves to a different conflicted file.
                .id(session.path)
            }
        } else {
            wholeFileResolver
        }
    }

    private func resolverToolbar(
        document: ConflictDocument,
        proxy: ScrollViewProxy
    ) -> some View {
        HStack(spacing: 10) {
            Text("\(session.resolvedCount) of \(document.hunks.count) resolved")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    session.resolvedCount == document.hunks.count
                        ? AppTheme.added
                        : AppTheme.secondary
                )
                .monospacedDigit()

            if document.hunks.count > 1 {
                HStack(spacing: 2) {
                    conflictStepButton(
                        symbol: "chevron.up",
                        help: "Previous Unresolved Conflict",
                        document: document,
                        proxy: proxy,
                        forward: false
                    )

                    conflictStepButton(
                        symbol: "chevron.down",
                        help: "Next Unresolved Conflict",
                        document: document,
                        proxy: proxy,
                        forward: true
                    )
                }
            }

            Spacer(minLength: 8)

            Button("Edit File Manually") {
                model.viewCurrentDiffInFiles()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(
                model.canViewCurrentDiffInFiles ? AppTheme.graphBlue : AppTheme.muted
            )
            .disabled(!model.canViewCurrentDiffInFiles)
            .help("Open the conflicted file in Files, with markers, to resolve it by hand")

            Menu("Resolve All") {
                Button("Use \(session.currentTitle)") {
                    model.chooseAllConflictHunks(.current)
                }

                Button("Use \(session.incomingTitle)") {
                    model.chooseAllConflictHunks(.incoming)
                }

                Button("Use Both") {
                    model.chooseAllConflictHunks(.both)
                }

                Divider()

                Button("Clear All Choices") {
                    model.clearConflictChoices()
                }
                .disabled(session.choices.isEmpty)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.isBusy || model.hasPendingChangeOperations)

            Button("Mark Resolved") {
                Task { await model.applyConflictResolution() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(session.resolvedText == nil ? AppTheme.muted : AppTheme.onAccent)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                session.resolvedText == nil ? AppTheme.disabledFill : AppTheme.actionBlue,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .disabled(
                session.resolvedText == nil
                    || model.isBusy
                    || model.hasPendingChangeOperations
            )
            .help("Write the selected results and stage this file")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(AppTheme.raisedFill)
    }

    private func conflictStepButton(
        symbol: String,
        help: String,
        document: ConflictDocument,
        proxy: ScrollViewProxy,
        forward: Bool
    ) -> some View {
        let unresolved = document.hunks.map(\.id).filter { session.choices[$0] == nil }
        return Button {
            jumpToUnresolved(unresolved, proxy: proxy, forward: forward)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(unresolved.isEmpty ? AppTheme.muted : AppTheme.secondary)
                .frame(width: 22, height: 22)
                .background(AppTheme.hover, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(unresolved.isEmpty)
        .help(help)
        .accessibilityLabel(help)
    }

    private func jumpToUnresolved(
        _ unresolved: [Int],
        proxy: ScrollViewProxy,
        forward: Bool
    ) {
        guard !unresolved.isEmpty else { return }
        let target: Int
        if forward {
            target = unresolved.first { $0 > (navigationCursor ?? -1) } ?? unresolved[0]
        } else {
            target = unresolved.last { $0 < (navigationCursor ?? .max) }
                ?? unresolved[unresolved.count - 1]
        }
        navigationCursor = target
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            proxy.scrollTo(target, anchor: .top)
        }
    }

    private var wholeFileResolver: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.conflict)

                Text("Choose a complete version")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.primary)

                Text("Compare both files, then keep one side.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.muted)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(AppTheme.raisedFill)

            Rectangle()
                .fill(AppTheme.edge)
                .frame(height: 1)

            HStack(spacing: 0) {
                ConflictWholeFilePane(
                    title: session.currentTitle,
                    role: "Current side",
                    side: wholeFileSide(model.gitFilePreview?.old),
                    choose: { keepWholeFile(.current) }
                )

                Rectangle()
                    .fill(AppTheme.edge)
                    .frame(width: 1)

                ConflictWholeFilePane(
                    title: session.incomingTitle,
                    role: "Incoming side",
                    side: wholeFileSide(model.gitFilePreview?.new),
                    choose: { keepWholeFile(.incoming) }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle()
                .fill(AppTheme.edge)
                .frame(height: 1)

            HStack(spacing: 14) {
                Button("Edit File Manually") {
                    model.viewCurrentDiffInFiles()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.graphBlue)
                .disabled(!model.canViewCurrentDiffInFiles)

                Spacer(minLength: 8)

                Button("Use Edited File") {
                    guard let change = model.selectedChange else { return }
                    Task { await model.stage(change) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.secondary)
                .disabled(
                    model.selectedChange == nil
                        || model.isBusy
                        || model.hasPendingChangeOperations
                )
                .help("Stage the current working-tree file as the resolved result")
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(AppTheme.raisedFill)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.diffCanvas)
    }

    private func wholeFileSide(
        _ version: GitFilePreviewVersion?
    ) -> ConflictWholeFileSide {
        guard model.gitFilePreview != nil else { return .unavailable }
        guard let version else { return .deleted }
        return .file(version)
    }

    private func keepWholeFile(_ version: ConflictVersion) {
        guard let change = model.selectedChange else { return }
        Task { await model.resolveConflict(change, keeping: version) }
    }
}

enum ConflictWholeFileSide: Equatable {
    case file(GitFilePreviewVersion)
    case deleted
    case unavailable

    var id: String {
        switch self {
        case .file(let version): return version.url.path
        case .deleted: return "deleted"
        case .unavailable: return "unavailable"
        }
    }
}

enum ConflictWholeFileContent: Sendable {
    case text(String)
    case quickLook
    case message(String)
}

struct ConflictWholeFilePane: View {
    let title: String
    let role: String
    let side: ConflictWholeFileSide
    let choose: () -> Void
    @State private var content: ConflictWholeFileContent?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(role)
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppTheme.muted)
                }

                Spacer(minLength: 6)

                Button("Use \(title)", action: choose)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppTheme.graphBlue)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(AppTheme.hover, in: RoundedRectangle(cornerRadius: 4))
                    .disabled(isLoading || side == .unavailable)
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(AppTheme.inputFill)

            Rectangle()
                .fill(AppTheme.edge)
                .frame(height: 1)

            contentView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: side.id) {
            await loadContent()
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch side {
        case .deleted:
            wholeFileMessage(
                symbol: "trash",
                title: "File deleted",
                detail: "This file does not exist on \(title)."
            )
        case .unavailable:
            wholeFileMessage(
                symbol: "doc.questionmark",
                title: "Preview unavailable",
                detail: "Open the file manually to inspect this side."
            )
        case .file(let version):
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch content {
                case .text(let text):
                    LargeSourceDocument(text: text, scrollRequest: nil)
                        .equatable()
                case .quickLook:
                    RepositoryFilePreview(url: version.url)
                        .padding(RepositoryFileLoader.isImage(at: version.url) ? 16 : 0)
                case .message(let message):
                    wholeFileMessage(
                        symbol: "doc.questionmark",
                        title: "Preview unavailable",
                        detail: message
                    )
                case nil:
                    EmptyView()
                }
            }
        }
    }

    private func wholeFileMessage(
        symbol: String,
        title: String,
        detail: String
    ) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(AppTheme.muted)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.secondary)

            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.diffCanvas)
    }

    private func loadContent() async {
        guard case .file(let version) = side else {
            content = nil
            isLoading = false
            return
        }
        content = nil
        isLoading = true
        let loaded = await Task.detached(priority: .userInitiated) {
            do {
                switch try RepositoryFileLoader.document(at: version.url) {
                case .source(let text), .largeSource(let text):
                    return ConflictWholeFileContent.text(text)
                case .preview:
                    return ConflictWholeFileContent.quickLook
                case .message(let message):
                    return ConflictWholeFileContent.message(message)
                }
            } catch {
                return ConflictWholeFileContent.message(error.localizedDescription)
            }
        }.value
        guard !Task.isCancelled else { return }
        content = loaded
        isLoading = false
    }
}

struct ConflictHunkView: View {
    let number: Int
    let hunk: ConflictHunk
    let contextBefore: ConflictContext?
    let contextAfter: ConflictContext?
    let currentTitle: String
    let incomingTitle: String
    let choice: ConflictChoice?
    let choose: (ConflictChoice?) -> Void
    @State private var isEditingCustom = false
    @State private var customDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Conflict \(number)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.primary)

                Text("Lines \(hunk.markerLine)–\(hunk.endLine)")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.muted)
                    .monospacedDigit()

                Spacer(minLength: 8)

                ConflictChoiceButton(
                    title: currentTitle,
                    selected: choice == .current,
                    action: { select(choice == .current ? nil : .current) }
                )

                ConflictChoiceButton(
                    title: incomingTitle,
                    selected: choice == .incoming,
                    action: { select(choice == .incoming ? nil : .incoming) }
                )

                ConflictChoiceButton(
                    title: "Both",
                    selected: choice == .both,
                    action: { select(choice == .both ? nil : .both) }
                )

                ConflictChoiceButton(
                    title: "Custom",
                    icon: "pencil",
                    selected: choice?.isCustom == true || isEditingCustom,
                    action: {
                        if isEditingCustom {
                            isEditingCustom = false
                        } else {
                            beginCustomEditing()
                        }
                    }
                )
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 38)
            .background(AppTheme.raisedFill)

            if let contextBefore {
                ConflictContextCode(context: contextBefore)
            }

            HStack(spacing: 0) {
                ConflictVersionPane(
                    title: currentTitle,
                    gitLabel: hunk.currentLabel,
                    text: hunk.currentText,
                    startLine: hunk.currentStartLine,
                    accent: AppTheme.graphBlue,
                    selected: choice == .current || choice == .both
                )

                Rectangle()
                    .fill(AppTheme.edge)
                    .frame(width: 1)

                ConflictVersionPane(
                    title: incomingTitle,
                    gitLabel: hunk.incomingLabel,
                    text: hunk.incomingText,
                    startLine: hunk.incomingStartLine,
                    accent: AppTheme.added,
                    selected: choice == .incoming || choice == .both
                )
            }

            if isEditingCustom {
                customEditor
            } else if case .custom(let text) = choice {
                customPreview(text)
            }

            if let contextAfter {
                ConflictContextCode(context: contextAfter)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.edge)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    /// Every explicit pick closes the inline editor so a stale draft never
    /// lingers under a different selection.
    private func select(_ newChoice: ConflictChoice?) {
        isEditingCustom = false
        choose(newChoice)
    }

    private func beginCustomEditing() {
        switch choice {
        case .custom(let text):
            customDraft = text
        case .current:
            customDraft = hunk.currentText
        case .incoming:
            customDraft = hunk.incomingText
        case .both, nil:
            customDraft = hunk.currentText + hunk.incomingText
        }
        isEditingCustom = true
    }

    private var customEditor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Custom Resolution")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.primary)

                Text("Replaces the conflicted block with this text")
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button("Cancel") {
                    isEditingCustom = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.secondary)

                Button("Use This Text") {
                    select(.custom(customDraft))
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.onAccent)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(AppTheme.actionBlue, in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(AppTheme.selection)

            TextEditor(text: $customDraft)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(AppTheme.primary)
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .frame(height: customEditorHeight)
                .background(AppTheme.diffCanvas)
                .accessibilityLabel("Custom resolution text")
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.edge)
                .frame(height: 1)
        }
    }

    private var customEditorHeight: CGFloat {
        let lines = customDraft.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
        return min(max(CGFloat(lines) * 16 + 22, 96), 240)
    }

    private func customPreview(_ text: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Custom Resolution")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.primary)

                Spacer(minLength: 0)

                Button("Edit…") {
                    beginCustomEditing()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.graphBlue)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(AppTheme.selection)

            if text.isEmpty {
                Text("No content. The conflicted block will be removed.")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(AppTheme.muted)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.selection.opacity(0.35))
            } else {
                ScrollView(.horizontal) {
                    ConflictCodeText(text: text, startLine: nil)
                        .padding(9)
                }
                .frame(maxHeight: 180)
                .background(AppTheme.selection.opacity(0.35))
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.edge)
                .frame(height: 1)
        }
    }
}

struct ConflictChoiceButton: View {
    let title: String
    var icon: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                }

                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(selected ? AppTheme.onAccent : AppTheme.secondary)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(
                selected ? AppTheme.actionBlue : AppTheme.hover,
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use \(title)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

struct ConflictVersionPane: View {
    let title: String
    let gitLabel: String
    let text: String
    let startLine: Int
    /// Side hue shared with the file editor's conflict regions: blue for the
    /// current side, green for the incoming side.
    let accent: Color
    let selected: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? AppTheme.primary : AppTheme.secondary)

                if !gitLabel.isEmpty {
                    Text(gitLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(selected ? accent.opacity(0.26) : AppTheme.inputFill)

            ScrollView([.horizontal, .vertical]) {
                Group {
                    if text.isEmpty {
                        Text("No content. This side deletes these lines.")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(AppTheme.muted)
                    } else {
                        ConflictCodeText(text: text, startLine: startLine)
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 72, idealHeight: 110, maxHeight: 180)
            .background(selected ? accent.opacity(0.12) : AppTheme.diffCanvas)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ConflictContextCode: View {
    let context: ConflictContext

    var body: some View {
        ScrollView(.horizontal) {
            ConflictCodeText(
                text: context.text,
                startLine: context.startLine,
                codeColor: AppTheme.muted
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.inputFill.opacity(0.72))
    }
}

/// Monospaced code with an optional right-aligned line-number gutter. The
/// gutter mirrors the working-tree file's numbering so the resolver matches
/// what an editor would show, and it stays outside text selection so copying
/// code never captures the numbers.
struct ConflictCodeText: View {
    let text: String
    let startLine: Int?
    var codeColor: Color = AppTheme.primary

    private var lineCount: Int {
        guard !text.isEmpty else { return 0 }
        let newlines = text.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        return newlines + (text.hasSuffix("\n") ? 0 : 1)
    }

    private var displayText: String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let startLine, lineCount > 0 {
                Text(
                    (startLine..<startLine + lineCount)
                        .map(String.init)
                        .joined(separator: "\n")
                )
                .foregroundStyle(AppTheme.muted.opacity(0.75))
                .multilineTextAlignment(.trailing)
            }

            Text(displayText)
                .foregroundStyle(codeColor)
                .textSelection(.enabled)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .fixedSize(horizontal: true, vertical: true)
    }
}

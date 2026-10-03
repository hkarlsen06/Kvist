import AppKit
import SwiftUI

struct GraphPanel: View {
    @EnvironmentObject private var model: RepositoryModel
    let isOpeningRepository: Bool
    @State private var revealHeadRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            GraphHeader {
                guard model.headHash != nil else { return }
                revealHeadRequest &+= 1
            }

            if isOpeningRepository || (model.repositoryURL == nil && model.isBusy) {
                GraphPanelLoadingContent()
            } else {
                GraphHistoryTable(revealHeadRequest: revealHeadRequest)
            }
        }
    }
}

struct GraphPanelLoadingContent: View {
    private let rowWidths: [CGFloat] = [176, 214, 148, 192]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rowWidths.enumerated()), id: \.offset) { index, width in
                HStack(spacing: 8) {
                    LoadingGraphMark(
                        isFirst: index == 0,
                        isLast: index == rowWidths.count - 1
                    )
                    .frame(width: 22, height: 32)

                    LoadingPlaceholder(width: width, height: 10, cornerRadius: 3)

                    if index == 0 || index == 2 {
                        LoadingPlaceholder(
                            width: index == 0 ? 48 : 62,
                            height: 16,
                            cornerRadius: 8
                        )
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 31)
                .frame(height: 32)
            }

            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }
}

struct LoadingGraphMark: View {
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(AppTheme.graphBlue.opacity(0.3))
                    .frame(width: 1, height: isFirst ? 16 : 14)
                    .opacity(isFirst ? 0 : 1)

                Rectangle()
                    .fill(AppTheme.graphBlue.opacity(0.3))
                    .frame(width: 1, height: isLast ? 16 : 18)
                    .opacity(isLast ? 0 : 1)
            }

            Circle()
                .stroke(AppTheme.graphBlue.opacity(0.5), lineWidth: 1.5)
                .frame(width: 8, height: 8)
                .background(AppTheme.canvas, in: Circle())
        }
    }
}

struct GraphHistoryTable: NSViewRepresentable {
    @EnvironmentObject private var model: RepositoryModel
    let revealHeadRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        // The automatic style resolves to the inset style and pads rows by
        // ~16pt per side, shrinking the commit-message column. Plain keeps
        // the full panel width for rows.
        table.style = .plain
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.wantsLayer = true
        table.layerContentsRedrawPolicy = .onSetNeedsDisplay
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Graph")))
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = table
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.install(scrollView: scrollView, tableView: table)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            model: model,
            revealHeadRequest: revealHeadRequest
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private enum DisplayRowKind: UInt8 {
            case commit
            case loading
            case empty
            case file
        }

        private struct DisplayRow {
            let kind: DisplayRowKind
            let graphIndex: Int
            let fileIndex: Int
        }

        private var model: RepositoryModel
        private weak var tableView: NSTableView?
        private weak var scrollView: NSScrollView?
        private var displayRows: [DisplayRow] = []
        private var graphRowCount = 0
        private var firstGraphID: String?
        private var lastGraphID: String?
        private var graphPublicationVersion = 0
        private var graphScope: GraphScope?
        private var expandedSignature: [String: Int] = [:]
        private var revealHeadRequest = 0
        private var boundsObserver: NSObjectProtocol?
        private weak var hoveredNestedCell: GraphNestedTableCell?
        private var selectedFileKey: String?

        init(model: RepositoryModel) {
            self.model = model
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        func install(scrollView: NSScrollView, tableView: NSTableView) {
            self.scrollView = scrollView
            self.tableView = tableView
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.loadMoreIfNeeded() }
            }
        }

        func update(model: RepositoryModel, revealHeadRequest: Int) {
            self.model = model
            guard let tableView else { return }
            let newExpandedSignature = expansionSignature(model: model)
            let newFirstID = model.graph.first?.id
            let newLastID = model.graph.last?.id
            let isAppend = newExpandedSignature.isEmpty
                && expandedSignature.isEmpty
                && model.graph.count > graphRowCount
                && model.graph.indices.contains(max(0, graphRowCount - 1))
                && model.graph[max(0, graphRowCount - 1)].id == lastGraphID
                && model.graph.first?.id == firstGraphID
                && model.graphScope == graphScope
            if isAppend {
                let oldDisplayCount = displayRows.count
                displayRows.append(contentsOf: (graphRowCount..<model.graph.count).map {
                    DisplayRow(kind: .commit, graphIndex: $0, fileIndex: -1)
                })
                let inserted = IndexSet(oldDisplayCount..<displayRows.count)
                tableView.insertRows(at: inserted, withAnimation: [])
            } else if model.graph.count != graphRowCount
                        || newFirstID != firstGraphID
                        || newLastID != lastGraphID
                        || model.graphPublicationVersion != graphPublicationVersion
                        || model.graphScope != graphScope
                        || newExpandedSignature != expandedSignature {
                displayRows = makeDisplayRows(model: model)
                tableView.reloadData()
            }
            graphRowCount = model.graph.count
            firstGraphID = newFirstID
            lastGraphID = newLastID
            graphPublicationVersion = model.graphPublicationVersion
            graphScope = model.graphScope
            expandedSignature = newExpandedSignature

            // File cells draw their own selection fill, so repaint them when
            // the selected historical file changes.
            let newSelectedFileKey = model.selectedCommitFile.map {
                "\(model.selectedCommit?.hash ?? "")\u{0}\($0.id)"
            }
            if newSelectedFileKey != selectedFileKey {
                selectedFileKey = newSelectedFileKey
                tableView.enumerateAvailableRowViews { rowView, _ in
                    for case let cell as GraphNestedTableCell in rowView.subviews {
                        cell.needsDisplay = true
                    }
                }
            }

            if revealHeadRequest != self.revealHeadRequest {
                self.revealHeadRequest = revealHeadRequest
                if let headHash = model.headHash,
                   let graphIndex = model.graph.firstIndex(where: {
                       $0.commit.hash == headHash
                   }),
                   let index = displayRows.firstIndex(where: {
                       $0.kind == .commit && $0.graphIndex == graphIndex
                   }) {
                    tableView.scrollRowToVisible(index)
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            displayRows.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard displayRows.indices.contains(row) else { return 32 }
            return displayRows[row].kind == .commit ? 32 : 28
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard displayRows.indices.contains(row) else { return nil }
            let displayRow = displayRows[row]
            guard model.graph.indices.contains(displayRow.graphIndex) else { return nil }
            let graphRow = model.graph[displayRow.graphIndex]
            switch displayRow.kind {
            case .commit:
                let identifier = NSUserInterfaceItemIdentifier("GraphCommit")
                let view = tableView.makeView(
                    withIdentifier: identifier,
                    owner: nil
                ) as? GraphCommitTableCell ?? GraphCommitTableCell()
                view.identifier = identifier
                view.configure(
                    row: graphRow,
                    model: model
                )
                return view
            case .loading:
                return nestedView(
                    tableView: tableView,
                    identifier: "GraphLoading",
                    row: graphRow,
                    commit: nil,
                    file: nil,
                    message: "Loading changed files…"
                )
            case .empty:
                return nestedView(
                    tableView: tableView,
                    identifier: "GraphEmpty",
                    row: graphRow,
                    commit: nil,
                    file: nil,
                    message: "No changed files"
                )
            case .file:
                let commit = graphRow.commit
                let files = model.files(for: commit)
                guard files.indices.contains(displayRow.fileIndex) else { return nil }
                return nestedView(
                    tableView: tableView,
                    identifier: "GraphFile",
                    row: graphRow,
                    commit: commit,
                    file: files[displayRow.fileIndex],
                    message: nil
                )
            }
        }

        private func loadMoreIfNeeded() {
            guard let scrollView, let tableView, model.canLoadMoreGraph,
                  !model.isLoadingMoreGraph else { return }
            let visibleBottom = scrollView.contentView.bounds.maxY
            if visibleBottom >= tableView.bounds.height - 160 {
                Task { await model.loadMoreGraph() }
            }
        }

        private func makeDisplayRows(model: RepositoryModel) -> [DisplayRow] {
            var result: [DisplayRow] = []
            result.reserveCapacity(model.graph.count + model.commitFilesByHash.values.reduce(0) {
                $0 + $1.count
            })
            for (graphIndex, row) in model.graph.enumerated() {
                result.append(DisplayRow(
                    kind: .commit,
                    graphIndex: graphIndex,
                    fileIndex: -1
                ))
                guard model.expandedCommitHashes.contains(row.commit.hash) else { continue }
                if model.loadingCommitFileHashes.contains(row.commit.hash) {
                    result.append(DisplayRow(
                        kind: .loading,
                        graphIndex: graphIndex,
                        fileIndex: -1
                    ))
                } else {
                    let files = model.files(for: row.commit)
                    if files.isEmpty {
                        result.append(DisplayRow(
                            kind: .empty,
                            graphIndex: graphIndex,
                            fileIndex: -1
                        ))
                    } else {
                        result.append(contentsOf: files.indices.map {
                            DisplayRow(
                                kind: .file,
                                graphIndex: graphIndex,
                                fileIndex: $0
                            )
                        })
                    }
                }
            }
            return result
        }

        private func expansionSignature(model: RepositoryModel) -> [String: Int] {
            Dictionary(uniqueKeysWithValues: model.expandedCommitHashes.map { hash in
                let count = model.loadingCommitFileHashes.contains(hash)
                    ? -1
                    : model.commitFilesByHash[hash]?.count ?? 0
                return (hash, count)
            })
        }

        private func nestedView(
            tableView: NSTableView,
            identifier rawIdentifier: String,
            row: GraphRow,
            commit: CommitInfo?,
            file: CommitFileChange?,
            message: String?
        ) -> GraphNestedTableCell {
            let identifier = NSUserInterfaceItemIdentifier(rawIdentifier)
            let view = tableView.makeView(
                withIdentifier: identifier,
                owner: nil
            ) as? GraphNestedTableCell ?? GraphNestedTableCell()
            view.identifier = identifier
            view.hoverChanged = { [weak self] cell, hovering in
                self?.setNestedCell(cell, hovering: hovering)
            }
            view.configure(
                row: row,
                commit: commit,
                file: file,
                message: message,
                model: model
            )
            return view
        }

        private func setNestedCell(
            _ cell: GraphNestedTableCell,
            hovering: Bool
        ) {
            if hovering {
                if hoveredNestedCell !== cell {
                    hoveredNestedCell?.setHovering(false)
                }
                hoveredNestedCell = cell
                cell.setHovering(true)
            } else {
                cell.setHovering(false)
                if hoveredNestedCell === cell {
                    hoveredNestedCell = nil
                }
            }
        }
    }
}

@MainActor
final class GraphCommitTableCell: NSView {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installHostingView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installHostingView()
    }

    func configure(row: GraphRow, model: RepositoryModel) {
        hostingView.rootView = AnyView(
            GraphCommitRow(row: row)
            .environmentObject(model)
        )
    }

    private func installHostingView() {
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }
}
@MainActor
final class GraphNestedTableCell: NSView {
    private weak var model: RepositoryModel?
    private var row: GraphRow?
    private var commit: CommitInfo?
    private var file: CommitFileChange?
    private var message: String?
    private var trackingAreaReference: NSTrackingArea?
    private var hovering = false
    private let laneWidth: CGFloat = 11
    var hoverChanged: ((GraphNestedTableCell, Bool) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    func configure(
        row: GraphRow,
        commit: CommitInfo?,
        file: CommitFileChange?,
        message: String?,
        model: RepositoryModel
    ) {
        // NSTableView recycles cells while scrolling. A recycled view may not
        // receive mouseExited before it is assigned to another file, so never
        // carry hover state across configurations.
        setHovering(false)
        self.row = row
        self.commit = commit
        self.file = file
        self.message = message
        self.model = model
        toolTip = file?.previousPath.map { "\($0) → \(file?.path ?? "")" }
            ?? file?.path
            ?? message
        setAccessibilityElement(true)
        setAccessibilityRole(file == nil ? .staticText : .button)
        setAccessibilityLabel(file?.path ?? message ?? "")
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        hoverChanged?(self, true)
    }

    override func mouseExited(with event: NSEvent) {
        hoverChanged?(self, false)
    }

    func setHovering(_ hovering: Bool) {
        guard self.hovering != hovering else { return }
        self.hovering = hovering
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0, let file, let commit, let model else { return }
        model.activate(file, in: commit)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let file, let commit, let model else { return false }
        model.activate(file, in: commit)
        return true
    }

    private var isSelected: Bool {
        guard let file, let model else { return false }
        return model.selectedCommitFile == file
            && model.selectedCommit?.hash == commit?.hash
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard file != nil else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Copy Path", action: #selector(copyPath), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func copyPath() {
        guard let file else { return }
        guard let model else { return }
        copyRepositoryFilePath(file.path, in: model)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let row else { return }
        if isSelected {
            AppTheme.selectionNSColor.setFill()
            dirtyRect.fill()
        } else if hovering, file != nil {
            NSColor(AppTheme.hover).setFill()
            dirtyRect.fill()
        }

        for (index, lane) in row.outputLanes.enumerated() {
            lane.color.nsColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.2
            let x = 9 + laneWidth * CGFloat(index + 1)
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: bounds.height))
            path.stroke()
        }
        let topologyWidth = laneWidth
            * CGFloat(max(row.inputLanes.count, row.outputLanes.count, 1) + 1)
        let textX = 9 + topologyWidth + 18

        if let file {
            let statusWidth: CGFloat = 18
            let statusRect = NSRect(
                x: bounds.maxX - 19 - statusWidth,
                y: 6,
                width: statusWidth,
                height: 17
            )
            drawText(
                file.status,
                in: statusRect,
                font: .monospacedSystemFont(ofSize: 12, weight: .semibold),
                color: statusColor(file.status),
                alignment: .right
            )
            let nameFont = NSFont.systemFont(ofSize: 13)
            let nameWidth = min(
                (file.name as NSString).size(withAttributes: [.font: nameFont]).width,
                max(0, bounds.width * 0.55)
            )
            drawText(
                file.name,
                in: NSRect(x: textX, y: 5, width: nameWidth, height: 18),
                font: nameFont,
                color: AppTheme.primaryNSColor,
                alignment: .left
            )
            if !file.parentPath.isEmpty {
                drawText(
                    file.parentPath,
                    in: NSRect(
                        x: textX + nameWidth + 8,
                        y: 6,
                        width: max(0, statusRect.minX - textX - nameWidth - 16),
                        height: 17
                    ),
                    font: .systemFont(ofSize: 12),
                    color: NSColor(AppTheme.secondary),
                    alignment: .left
                )
            }
        } else if let message {
            drawText(
                message,
                in: NSRect(
                    x: textX,
                    y: 5,
                    width: max(0, bounds.maxX - textX - 18),
                    height: 18
                ),
                font: .systemFont(ofSize: 12),
                color: AppTheme.mutedNSColor,
                alignment: .left
            )
        }
    }

    private func statusColor(_ status: String) -> NSColor {
        switch status {
        case "A": return NSColor(AppTheme.added)
        case "D": return NSColor(AppTheme.deleted)
        case "R", "C": return NSColor(AppTheme.graphBlue)
        default: return NSColor(AppTheme.modified)
        }
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }
}

struct GraphHeader: View {
    @EnvironmentObject private var model: RepositoryModel
    let revealHead: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text("GRAPH")
                .font(AppType.panelTitle)
                .tracking(0.8)
                .foregroundStyle(AppTheme.secondary)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            ViewThatFits(in: .horizontal) {
                controls(spacing: 12, showsScopeTitle: true)
                controls(spacing: 6, showsScopeTitle: false)
            }
        }
        .foregroundStyle(AppTheme.primary)
        .padding(.leading, 22)
        .padding(.trailing, 21)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
    }

    /// Narrow panes drop the scope title and tighten the spacing so every
    /// control stays visible.
    private func controls(spacing: CGFloat, showsScopeTitle: Bool) -> some View {
        HStack(spacing: spacing) {
            Menu {
                ForEach(GraphScope.allCases) { scope in
                    Button {
                        Task { await model.setGraphScope(scope) }
                    } label: {
                        if model.graphScope == scope {
                            Label(
                                graphScopeDescription(scope),
                                systemImage: "checkmark"
                            )
                        } else {
                            Text(graphScopeDescription(scope))
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    BranchGlyph(size: 14, color: AppTheme.primary)
                    if showsScopeTitle {
                        Text(model.graphScope.title)
                    }
                }
                .font(AppType.rowDetail)
                .frame(width: showsScopeTitle ? 72 : 18, height: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .contentShape(Rectangle())
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .tint(AppTheme.primary)
            .accessibilityLabel("Graph Scope")
            .accessibilityValue(graphScopeDescription(model.graphScope))
            .disabled(operationsDisabled)

            CodiconButton(icon: .target, help: "Reveal Current HEAD", action: revealHead)
                .disabled(!headIsVisible || operationsDisabled)

            CodiconButton(icon: .repoFetch, help: "Fetch All Remotes") {
                Task { await model.fetch() }
            }
            .disabled(operationsDisabled)

            Menu {
                Button("Pull") {
                    Task { await model.pull() }
                }

                Button("Pull with Rebase") {
                    Task { await model.pullRebasing() }
                }
            } label: {
                CodiconGlyph(
                    icon: .repoPull,
                    size: 16,
                    color: AppTheme.primary
                )
                    .frame(width: 25, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 25, height: 28)
            .contentShape(Rectangle())
            .tint(AppTheme.primary)
            .help("Pull")
            .accessibilityLabel("Pull Options")
            .disabled(
                operationsDisabled || !model.hasUpstream
            )

            CodiconButton(
                icon: .repoPush,
                help: model.hasUpstream ? "Push" : "Publish Branch"
            ) {
                Task { await model.pushOrPublish() }
            }
            .disabled(
                operationsDisabled
                    || (!model.hasUpstream
                        && (model.branch == "detached HEAD" || model.headHash == nil))
            )

            Menu {
                Button("Force Push with Lease…") {
                    Task { await model.forcePushWithLease() }
                }

                Button("Force Push Without Lease…") {
                    Task { await model.forcePush() }
                }
            } label: {
                Image(systemName: "cloud.bolt")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(AppTheme.primary)
                    .frame(width: 25, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 25, height: 28)
            .contentShape(Rectangle())
            .tint(AppTheme.primary)
            .help("Force Push")
            .accessibilityLabel("Force Push")
            .disabled(
                operationsDisabled
                    || !model.hasUpstream
                    || model.branch == "detached HEAD"
            )

            repositoryMenu

        }
    }

    private var headIsVisible: Bool {
        guard let headHash = model.headHash else { return false }
        return model.graph.contains(where: { $0.commit.hash == headHash })
    }

    private var operationsDisabled: Bool {
        model.isBusy
            || model.isGeneratingCommitMessage
            || model.hasPendingChangeOperations
    }

    private var repositoryMenu: some View {
        Menu {
            Menu("Remotes") {
                if model.remotes.isEmpty {
                    Text("No remotes")
                } else {
                    ForEach(model.remotes, id: \.name) { remote in
                        Menu(remote.name) {
                            Button("Edit URL…") {
                                guard let url = GitPrompt.remoteURL(for: remote) else { return }
                                Task { await model.editRemote(remote, url: url) }
                            }

                            Button("Remove Remote…", role: .destructive) {
                                Task { await model.removeRemote(remote) }
                            }
                        }
                    }
                }

                Divider()

                Button("Add Remote…") {
                    guard let remote = GitPrompt.newRemote() else { return }
                    Task { await model.addRemote(name: remote.name, url: remote.url) }
                }
            }

            Menu("Upstream") {
                if remoteBranchReferences.isEmpty {
                    Text("No remote branches")
                } else {
                    ForEach(remoteBranchReferences) { reference in
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
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppTheme.primary)
                .frame(width: 25, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 25, height: 28)
        .contentShape(Rectangle())
        .tint(AppTheme.primary)
        .help("Repository Settings")
        .accessibilityLabel("Repository Settings")
        .disabled(operationsDisabled)
    }

    private var remoteBranchReferences: [GitReference] {
        model.references
            .filter { $0.kind == .remoteBranch && !$0.name.hasSuffix("/HEAD") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func graphScopeDescription(_ scope: GraphScope) -> String {
        switch scope {
        case .all: return "All Branches"
        case .current: return "Current Branch"
        case .everything: return "Everything (All Git Refs)"
        case .reflog: return "Reflog Recovery"
        }
    }
}

struct GraphCommitRow: View {
    @EnvironmentObject private var model: RepositoryModel
    let row: GraphRow
    @State private var hovering = false

    var body: some View {
        let presentedItems = GraphReferencePresentation.displayItems(
            row.commit.references,
            upstreamReferenceID: model.upstreamReference?.id
        )
        let presentedReferenceIDs = Set(presentedItems.flatMap {
            [$0.reference.id] + $0.syncedRemotes.map(\.id)
        })
        let visibleItems = Array(presentedItems.prefix(2))
        let hiddenReferences = presentedItems
            .dropFirst(visibleItems.count)
            .map(\.reference)
        VStack(spacing: 0) {
            Button {
                model.toggleCommitExpansion(row.commit)
            } label: {
                HStack(spacing: 8) {
                    GraphTopology(row: row)

                    Text(row.commit.displaySubject)
                        .font(isHead ? AppType.rowEmphasis : AppType.row)
                        .foregroundStyle(AppTheme.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(2)

                    ForEach(visibleItems) { item in
                        BranchPill(
                            reference: item.reference,
                            syncedRemotes: item.syncedRemotes,
                            commitIsHead: isHead,
                            referenceIDsAtCommit: presentedReferenceIDs
                        )
                    }

                    if !hiddenReferences.isEmpty {
                        Text("+\(hiddenReferences.count)")
                            .font(AppType.captionEmphasis)
                            .foregroundStyle(AppTheme.secondary)
                            .fixedSize()
                            .help(hiddenReferences.map(referenceDescription).joined(separator: "\n"))
                            .contextMenu {
                                ForEach(Array(hiddenReferences)) { reference in
                                    Menu(reference.name) {
                                        ReferenceContextMenuItems(
                                            reference: reference,
                                            commitIsHead: isHead,
                                            referenceIDsAtCommit: presentedReferenceIDs
                                        )
                                    }
                                }
                            }
                    }

                }
                .padding(.leading, 9)
                .padding(.trailing, 18)
                .frame(height: 32)
                .contentShape(Rectangle())
                .background(hovering ? AppTheme.hover : .clear)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(commitHelp)
            .accessibilityLabel(
                "\(row.commit.displaySubject), \(row.commit.shortHash), by \(row.commit.author), \(row.commit.relativeDate)"
            )
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .contextMenu {
                if row.commit.isStash {
                    stashContextMenu
                } else {
                    commitContextMenu
                }
            }
        }
    }

    private var isHead: Bool {
        row.kind == .head
    }

    private var isExpanded: Bool {
        model.expandedCommitHashes.contains(row.commit.hash)
    }

    private var displayReferences: [GitReference] {
        GraphReferencePresentation.displayReferences(
            row.commit.references,
            upstreamReferenceID: model.upstreamReference?.id
        )
    }

    private var checkoutReferences: [GitReference] {
        guard !isHead else { return [] }
        return displayReferences.filter { $0.kind != .other && !$0.isHead }
    }

    private var comparisonReferences: [GitReference] {
        let selectedReferenceIDs = Set(displayReferences.map(\.id))
        return model.references.filter {
            !$0.name.hasSuffix("/HEAD")
                && $0.id != model.upstreamReference?.id
                && !selectedReferenceIDs.contains($0.id)
        }
    }

    private var hasGitHubOrigin: Bool {
        model.remotes.contains { $0.name == "origin" && $0.isGitHub }
    }

    private var githubPullRequestReferences: [GitReference] {
        displayReferences
            .filter { reference in
                guard let remoteBranch = reference.remoteBranchComponents,
                      remoteBranch.branch != "HEAD" else { return false }
                return model.remotes.contains {
                    $0.name == remoteBranch.remote && $0.isGitHub
                }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var operationsDisabled: Bool {
        model.isBusy
            || model.isGeneratingCommitMessage
            || model.hasPendingChangeOperations
    }

    @ViewBuilder
    private var stashContextMenu: some View {
        Button("Show Changes") {
            model.openCommitChanges(row.commit)
        }

        Divider()

        Button("Apply Stash") {
            Task { await model.applyStash(row.commit) }
        }
        .disabled(operationsDisabled)

        Button("Pop Stash") {
            Task { await model.popStash(row.commit) }
        }
        .disabled(operationsDisabled)

        Button("Delete Stash…") {
            guard GitPrompt.confirmDelete(
                kind: "stash",
                name: row.commit.subject
            ) else { return }
            Task { await model.dropStash(row.commit) }
        }
        .disabled(operationsDisabled)

        Divider()

        Button("Copy Commit Hash") {
            copyToPasteboard(row.commit.hash)
        }

        Button("Copy Commit Message") {
            Task { await model.copyCommitMessage(row.commit) }
        }
    }

    @ViewBuilder
    private var commitContextMenu: some View {
        Button("Show Changes") {
            model.openCommitChanges(row.commit)
        }

        if hasGitHubOrigin {
            Button("View Commit on GitHub") {
                Task {
                    if let url = await model.githubURL(for: row.commit) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        if githubPullRequestReferences.count == 1,
           let reference = githubPullRequestReferences.first {
            Button("Create PR on GitHub") {
                openGitHubPullRequest(for: reference)
            }
        } else if !githubPullRequestReferences.isEmpty {
            Menu("Create PR on GitHub") {
                ForEach(githubPullRequestReferences) { reference in
                    Button(reference.name) {
                        openGitHubPullRequest(for: reference)
                    }
                }
            }
        }

        Divider()

        if checkoutReferences.count == 1, let reference = checkoutReferences.first {
            Button(checkoutTitle(for: reference)) {
                Task { await model.checkout(reference) }
            }
            .disabled(operationsDisabled)
        } else if !checkoutReferences.isEmpty {
            Menu("Checkout") {
                referenceMenuItems(
                    checkoutReferences,
                    action: { reference in
                        Task { await model.checkout(reference) }
                    }
                )
            }
            .disabled(operationsDisabled)
        }

        if !isHead {
            Button("Checkout Commit (Detached HEAD)") {
                Task { await model.checkoutDetached(row.commit) }
            }
            .disabled(operationsDisabled)
        }

        Divider()

        Button("Create Branch from Commit…") {
            guard let name = GitPrompt.branchName(at: row.commit) else { return }
            Task { await model.createBranch(named: name, at: row.commit) }
        }
        .disabled(operationsDisabled)

        Button("Create Tag from Commit…") {
            guard let tag = GitPrompt.tag(at: row.commit) else { return }
            Task {
                await model.createTag(
                    named: tag.name,
                    message: tag.message,
                    at: row.commit
                )
            }
        }
        .disabled(operationsDisabled)

        Divider()

        if !isHead {
            Button("Cherry-Pick Commit") {
                Task { await model.cherryPick(row.commit) }
            }
            .disabled(operationsDisabled)
        }

        if row.commit.parentHashes.count <= 1 {
            Button("Revert Commit…") {
                Task { await model.revert(row.commit) }
            }
            .disabled(operationsDisabled)
        }

        if !isHead, !model.branch.isEmpty, model.branch != "detached HEAD" {
            Menu("Reset \"\(model.branch)\" to This Commit") {
                Button("Soft Reset (Keep Changes Staged)…") {
                    Task { await model.reset(to: row.commit, mode: .soft) }
                }

                Button("Mixed Reset (Keep Changes Unstaged)…") {
                    Task { await model.reset(to: row.commit, mode: .mixed) }
                }

                Divider()

                Button("Hard Reset (Discard Changes)…") {
                    Task { await model.reset(to: row.commit, mode: .hard) }
                }
            }
            .disabled(operationsDisabled)
        }

        if model.upstreamReference != nil || !comparisonReferences.isEmpty {
            Divider()

            Menu("Compare") {
                if let upstream = model.upstreamReference {
                    Button("With \(upstream.name)") {
                        model.compareWithUpstream(row.commit)
                    }

                    Button("Changes Since Divergence from \(upstream.name)") {
                        model.compareWithUpstream(
                            row.commit,
                            fromMergeBase: true
                        )
                    }
                }

                if !comparisonReferences.isEmpty {
                    if model.upstreamReference != nil {
                        Divider()
                    }

                    Menu("With Branch or Tag") {
                        referenceMenuItems(
                            comparisonReferences,
                            action: { reference in
                                model.compare(row.commit, against: reference)
                            }
                        )
                    }
                }
            }
            .disabled(operationsDisabled)
        }

        Divider()

        Button("Copy Commit Hash") {
            copyToPasteboard(row.commit.hash)
        }

        Button("Copy Commit Message") {
            Task { await model.copyCommitMessage(row.commit) }
        }
    }

    private func checkoutTitle(for reference: GitReference) -> String {
        switch reference.kind {
        case .tag:
            return "Checkout Tag \"\(reference.name)\""
        case .localBranch, .remoteBranch, .other:
            return "Checkout \"\(reference.name)\""
        }
    }

    @ViewBuilder
    private func referenceMenuItems(
        _ references: [GitReference],
        action: @escaping (GitReference) -> Void
    ) -> some View {
        let localBranches = references.filter { $0.kind == .localBranch }
        let remoteBranches = references.filter { $0.kind == .remoteBranch }
        let tags = references.filter { $0.kind == .tag }

        if !localBranches.isEmpty {
            Section("Branches") {
                ForEach(localBranches) { reference in
                    Button(reference.name) {
                        action(reference)
                    }
                }
            }
        }

        if !remoteBranches.isEmpty {
            Section("Remote Branches") {
                ForEach(remoteBranches) { reference in
                    Button(reference.name) {
                        action(reference)
                    }
                }
            }
        }

        if !tags.isEmpty {
            Section("Tags") {
                ForEach(tags) { reference in
                    Button(reference.name) {
                        action(reference)
                    }
                }
            }
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func openGitHubPullRequest(for reference: GitReference) {
        Task {
            if let url = await model.githubPullRequestURL(for: reference) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private var commitHelp: String {
        var lines = [
            row.commit.displaySubject,
            "\(row.commit.shortHash) · \(row.commit.author) · \(row.commit.relativeDate)"
        ]
        if let selector = row.commit.reflogSelector {
            lines.insert("\(selector) · \(row.commit.subject)", at: 1)
        }
        if !displayReferences.isEmpty {
            lines.append(displayReferences.map(referenceDescription).joined(separator: "\n"))
        }
        return lines.joined(separator: "\n")
    }

    private func referenceDescription(_ reference: GitReference) -> String {
        switch reference.kind {
        case .localBranch:
            return "Local branch: \(reference.name)"
        case .remoteBranch:
            return "Remote branch: \(reference.name)"
        case .tag:
            return "Tag: \(reference.name)"
        case .other:
            return reference.name
        }
    }
}

enum GraphReferencePresentation {
    struct DisplayItem: Identifiable, Hashable {
        let reference: GitReference
        /// Remote branches on the same commit that track this local branch
        /// (`origin/main` on `main`). Folded into the local pill so a synced
        /// branch shows one badge and the commit message keeps its width.
        let syncedRemotes: [GitReference]

        var id: String { reference.id }
    }

    static func displayItems(
        _ references: [GitReference],
        upstreamReferenceID: String?
    ) -> [DisplayItem] {
        let ordered = displayReferences(
            references,
            upstreamReferenceID: upstreamReferenceID
        )
        let localNames = Set(
            ordered.filter { $0.kind == .localBranch }.map(\.name)
        )
        var syncedRemotesByLocalName: [String: [GitReference]] = [:]
        var items: [DisplayItem] = []

        for reference in ordered where reference.kind == .remoteBranch {
            guard let localName = trackedLocalName(of: reference),
                  localNames.contains(localName) else { continue }
            syncedRemotesByLocalName[localName, default: []].append(reference)
        }

        for reference in ordered {
            if reference.kind == .remoteBranch,
               let localName = trackedLocalName(of: reference),
               localNames.contains(localName) {
                continue
            }
            items.append(DisplayItem(
                reference: reference,
                syncedRemotes: reference.kind == .localBranch
                    ? syncedRemotesByLocalName[reference.name] ?? []
                    : []
            ))
        }
        return items
    }

    /// `origin/main` tracks `main`: the branch name after the remote's own
    /// name. Nil when the name has no remote prefix to strip.
    private static func trackedLocalName(of reference: GitReference) -> String? {
        let components = reference.name.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2, !components[1].isEmpty else { return nil }
        return String(components[1])
    }

    static func displayReferences(
        _ references: [GitReference],
        upstreamReferenceID: String?
    ) -> [GitReference] {
        var seenNames = Set<String>()
        return references
            .filter { reference in
                !(reference.kind == .remoteBranch && reference.name.hasSuffix("/HEAD"))
            }
            .sorted { lhs, rhs in
                let lhsPriority = priority(
                    of: lhs,
                    upstreamReferenceID: upstreamReferenceID
                )
                let rhsPriority = priority(
                    of: rhs,
                    upstreamReferenceID: upstreamReferenceID
                )
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                if lhs.name != rhs.name {
                    return lhs.name < rhs.name
                }
                return lhs.id < rhs.id
            }
            .filter { seenNames.insert($0.name).inserted }
    }

    private static func priority(
        of reference: GitReference,
        upstreamReferenceID: String?
    ) -> Int {
        if reference.isHead { return 0 }
        if reference.id == upstreamReferenceID { return 1 }
        switch reference.kind {
        case .localBranch: return 2
        case .remoteBranch: return 3
        case .tag: return 4
        case .other: return 5
        }
    }
}

@MainActor
func copyRepositoryFilePath(_ relativePath: String, in model: RepositoryModel) {
    guard let repositoryURL = model.repositoryURL else { return }

    let path = model.sshRepository?.location(ofRelativePath: relativePath)
        ?? URL(fileURLWithPath: relativePath, relativeTo: repositoryURL)
            .standardizedFileURL
            .path

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
}

func revealRepositoryFileInFinder(_ relativePath: String, repositoryURL: URL?) {
    guard let repositoryURL else { return }

    let url = URL(
        fileURLWithPath: relativePath,
        relativeTo: repositoryURL
    )
    .standardizedFileURL

    NSWorkspace.shared.activateFileViewerSelecting([url])
}

enum GraphTopologyMetrics {
    static func nodeIndex(for row: GraphRow) -> Int {
        row.inputLanes.firstIndex(where: { $0.id == row.commit.hash })
            ?? row.inputLanes.count
    }

    static func width(for row: GraphRow, laneWidth: CGFloat) -> CGFloat {
        let nodeLaneCount = nodeIndex(for: row) + 1
        let visibleLaneCount = [
            row.inputLanes.count,
            row.outputLanes.count,
            nodeLaneCount,
            1
        ].max() ?? 1
        return laneWidth * CGFloat(visibleLaneCount + 1)
    }
}

struct GraphTopology: View {
    let row: GraphRow

    private let laneWidth: CGFloat = 11
    private let rowHeight: CGFloat = 32
    private let curveRadius: CGFloat = 5

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, _ in
            drawGraph(context: &context)
        }
        .frame(width: graphWidth, height: rowHeight)
        .accessibilityHidden(true)
    }

    private var graphWidth: CGFloat {
        GraphTopologyMetrics.width(for: row, laneWidth: laneWidth)
    }

    private func drawGraph(context: inout GraphicsContext) {
        let inputIndex = row.inputLanes.firstIndex(where: { $0.id == row.commit.hash })
        let circleIndex = GraphTopologyMetrics.nodeIndex(for: row)
        let circleX = x(for: circleIndex)
        let middleY = rowHeight / 2
        let circleColor = laneColor(at: circleIndex)
        let nodeColor = circleColor

        var outputIndex = 0
        for index in row.inputLanes.indices {
            let lane = row.inputLanes[index]
            let color = lane.color.swiftUIColor

            if lane.id == row.commit.hash {
                if index != circleIndex {
                    var path = Path()
                    path.move(to: CGPoint(x: x(for: index), y: 0))
                    appendConnection(
                        to: &path,
                        fromX: x(for: index),
                        toX: circleX,
                        middleY: middleY,
                        continueToBottom: false
                    )
                    stroke(path, color: color, context: &context)
                } else if !row.commit.parentHashes.isEmpty {
                    outputIndex += 1
                }
            } else if outputIndex < row.outputLanes.count,
                      lane.id == row.outputLanes[outputIndex].id {
                if index == outputIndex {
                    var path = Path()
                    path.move(to: CGPoint(x: x(for: index), y: 0))
                    path.addLine(to: CGPoint(x: x(for: index), y: rowHeight))
                    stroke(path, color: color, context: &context)
                } else {
                    var path = Path()
                    path.move(to: CGPoint(x: x(for: index), y: 0))
                    appendConnection(
                        to: &path,
                        fromX: x(for: index),
                        toX: x(for: outputIndex),
                        middleY: middleY,
                        continueToBottom: true
                    )
                    stroke(path, color: color, context: &context)
                }
                outputIndex += 1
            }
        }

        for parentHash in row.commit.parentHashes.dropFirst() {
            guard let parentIndex = row.outputLanes.lastIndex(where: { $0.id == parentHash }) else {
                continue
            }
            let parentX = x(for: parentIndex)
            let direction: CGFloat = parentX >= circleX ? 1 : -1
            var path = Path()
            path.move(to: CGPoint(x: circleX, y: middleY))
            path.addLine(to: CGPoint(
                x: parentX - (direction * curveRadius),
                y: middleY
            ))
            path.addCurve(
                to: CGPoint(x: parentX, y: middleY + curveRadius),
                control1: CGPoint(x: parentX, y: middleY),
                control2: CGPoint(x: parentX, y: middleY)
            )
            path.addLine(to: CGPoint(x: parentX, y: rowHeight))
            stroke(
                path,
                color: row.outputLanes[parentIndex].color.swiftUIColor,
                context: &context
            )
        }

        if let inputIndex {
            var incoming = Path()
            incoming.move(to: CGPoint(x: circleX, y: 0))
            incoming.addLine(to: CGPoint(x: circleX, y: middleY))
            stroke(
                incoming,
                color: row.inputLanes[inputIndex].color.swiftUIColor,
                context: &context
            )
        }

        if !row.commit.parentHashes.isEmpty {
            var outgoing = Path()
            outgoing.move(to: CGPoint(x: circleX, y: middleY))
            outgoing.addLine(to: CGPoint(x: circleX, y: rowHeight))
            stroke(outgoing, color: circleColor, context: &context)
        }

        drawNode(
            at: CGPoint(x: circleX, y: middleY),
            color: nodeColor,
            context: &context
        )
    }

    private func appendConnection(
        to path: inout Path,
        fromX: CGFloat,
        toX: CGFloat,
        middleY: CGFloat,
        continueToBottom: Bool
    ) {
        guard fromX != toX else {
            path.addLine(to: CGPoint(x: fromX, y: continueToBottom ? rowHeight : middleY))
            return
        }

        let direction: CGFloat = toX > fromX ? 1 : -1
        path.addLine(to: CGPoint(x: fromX, y: middleY - curveRadius))
        path.addCurve(
            to: CGPoint(x: fromX + (direction * curveRadius), y: middleY),
            control1: CGPoint(x: fromX, y: middleY),
            control2: CGPoint(x: fromX, y: middleY)
        )
        path.addLine(to: CGPoint(x: toX - (direction * curveRadius), y: middleY))

        if continueToBottom {
            path.addCurve(
                to: CGPoint(x: toX, y: middleY + curveRadius),
                control1: CGPoint(x: toX, y: middleY),
                control2: CGPoint(x: toX, y: middleY)
            )
            path.addLine(to: CGPoint(x: toX, y: rowHeight))
        } else {
            path.addLine(to: CGPoint(x: toX, y: middleY))
        }
    }

    private func drawNode(
        at point: CGPoint,
        color: Color,
        context: inout GraphicsContext
    ) {
        if row.kind == .head {
            let outer = Path(ellipseIn: CGRect(
                x: point.x - 7,
                y: point.y - 7,
                width: 14,
                height: 14
            ))
            context.fill(outer, with: .color(AppTheme.canvas))
            context.stroke(outer, with: .color(color), lineWidth: 2)

            let inner = Path(ellipseIn: CGRect(
                x: point.x - 2,
                y: point.y - 2,
                width: 4,
                height: 4
            ))
            context.fill(inner, with: .color(color))
        } else if row.commit.parentHashes.count > 1 {
            let outer = Path(ellipseIn: CGRect(
                x: point.x - 6,
                y: point.y - 6,
                width: 12,
                height: 12
            ))
            context.fill(outer, with: .color(AppTheme.canvas))
            context.stroke(outer, with: .color(color), lineWidth: 2)

            let inner = Path(ellipseIn: CGRect(
                x: point.x - 3,
                y: point.y - 3,
                width: 6,
                height: 6
            ))
            context.stroke(inner, with: .color(color), lineWidth: 2)
        } else {
            let circle = Path(ellipseIn: CGRect(
                x: point.x - 5,
                y: point.y - 5,
                width: 10,
                height: 10
            ))
            context.fill(circle, with: .color(color))
        }
    }

    private func stroke(
        _ path: Path,
        color: Color,
        context: inout GraphicsContext
    ) {
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        )
    }

    private func x(for index: Int) -> CGFloat {
        laneWidth * CGFloat(index + 1)
    }

    private func laneColor(at index: Int) -> Color {
        if index < row.outputLanes.count {
            return row.outputLanes[index].color.swiftUIColor
        }
        if index < row.inputLanes.count {
            return row.inputLanes[index].color.swiftUIColor
        }
        return AppTheme.graphBlue
    }
}

struct ReferenceContextMenuItems: View {
    @EnvironmentObject private var model: RepositoryModel
    let reference: GitReference
    let commitIsHead: Bool
    let referenceIDsAtCommit: Set<String>

    @ViewBuilder
    var body: some View {
        switch reference.kind {
        case .localBranch:
            if !reference.isHead {
                checkoutButton
            }

            if canMergeIntoCurrent || !rebaseTargets.isEmpty {
                if !reference.isHead {
                    Divider()
                }

                if canMergeIntoCurrent {
                    mergeIntoCurrentButton
                }

                rebaseAction

                Divider()
            }

            if let githubPullRequestReference {
                createGitHubPullRequestButton(for: githubPullRequestReference)

                Divider()
            }

            Button("Rename \"\(reference.name)\"…") {
                guard let name = GitPrompt.renamedBranch(reference) else { return }
                Task { await model.renameBranch(reference, to: name) }
            }
            .disabled(operationsDisabled)

            if !reference.isHead {
                Divider()

                Button("Delete Branch \"\(reference.name)\"…", role: .destructive) {
                    Task { await model.deleteBranchWithConfirmation(reference) }
                }
                .disabled(operationsDisabled)
            }

        case .remoteBranch:
            if !commitIsHead {
                checkoutButton
            }

            if githubPullRequestReference != nil {
                Divider()

                createGitHubPullRequestButton(for: reference)
            }

            if canMergeIntoCurrent {
                Divider()

                mergeIntoCurrentButton
            }

            if !commitIsHead || canMergeIntoCurrent {
                Divider()
            }

            Button("Delete Remote Branch \"\(reference.name)\"…", role: .destructive) {
                Task { await model.deleteBranchWithConfirmation(reference) }
            }
            .disabled(operationsDisabled)

        case .tag:
            if !commitIsHead {
                checkoutButton
            }

            if !model.remotes.isEmpty {
                Menu("Push Tag to Remote") {
                    ForEach(model.remotes, id: \.name) { remote in
                        Button(remote.name) {
                            Task { await model.pushTag(reference, to: remote) }
                        }
                    }
                }
                .disabled(operationsDisabled)

                Menu("Delete Tag from Remote") {
                    ForEach(model.remotes, id: \.name) { remote in
                        Button(remote.name, role: .destructive) {
                            Task { await model.deleteRemoteTag(reference, from: remote) }
                        }
                    }
                }
                .disabled(operationsDisabled)
            }

            if !commitIsHead || !model.remotes.isEmpty {
                Divider()
            }

            Button("Delete Tag \"\(reference.name)\"…", role: .destructive) {
                guard GitPrompt.confirmDelete(
                    kind: "tag",
                    name: reference.name
                ) else { return }
                Task { await model.deleteTag(reference) }
            }
            .disabled(operationsDisabled)

        case .other:
            Button("Copy Reference Name") {
                copyReferenceName()
            }
        }
    }

    @ViewBuilder
    private var mergeIntoCurrentButton: some View {
        if model.canFastForwardToHead(reference) {
            // Merging would change nothing, but the branch can catch up to
            // HEAD without checking it out.
            Button("Fast-Forward \"\(reference.name)\" to \"\(model.branch)\"") {
                Task { await model.fastForwardToHead(reference) }
            }
            .disabled(operationsDisabled)
        } else if model.canFastForward(to: reference) {
            Button("Fast-Forward \"\(model.branch)\" to \"\(reference.name)\"") {
                Task {
                    await model.integrate(
                        reference,
                        strategy: .fastForward
                    )
                }
            }
            .disabled(operationsDisabled)
        } else {
            Button("Merge \"\(reference.name)\" into \"\(model.branch)\"") {
                Task {
                    await model.integrate(
                        reference,
                        strategy: .merge
                    )
                }
            }
            .disabled(operationsDisabled)
        }
    }

    @ViewBuilder
    private var rebaseAction: some View {
        if rebaseTargets.count == 1, let target = rebaseTargets.first {
            rebaseButton(onto: target, includesBranchName: true)
        } else if !rebaseTargets.isEmpty {
            Menu("Rebase \"\(reference.name)\" onto") {
                if !localRebaseTargets.isEmpty {
                    Section("Branches") {
                        ForEach(localRebaseTargets) { target in
                            rebaseButton(onto: target)
                        }
                    }
                }

                if !remoteRebaseTargets.isEmpty {
                    Section("Remote Branches") {
                        ForEach(remoteRebaseTargets) { target in
                            rebaseButton(onto: target)
                        }
                    }
                }
            }
            .disabled(operationsDisabled)
        }
    }

    private func rebaseButton(
        onto target: GitReference,
        includesBranchName: Bool = false
    ) -> some View {
        Button(
            includesBranchName
                ? "Rebase \"\(reference.name)\" onto \"\(target.name)\""
                : target.name
        ) {
            Task { await model.rebase(reference, onto: target) }
        }
        .disabled(operationsDisabled)
    }

    private var checkoutButton: some View {
        Button(checkoutTitle) {
            Task { await model.checkout(reference) }
        }
        .disabled(operationsDisabled)
    }

    private var checkoutTitle: String {
        reference.kind == .tag
            ? "Checkout Tag \"\(reference.name)\""
            : "Checkout \"\(reference.name)\""
    }

    @ViewBuilder
    private func createGitHubPullRequestButton(for remoteBranch: GitReference) -> some View {
        Button("Create PR on GitHub") {
            Task {
                if let url = await model.githubPullRequestURL(for: remoteBranch) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private var githubPullRequestReference: GitReference? {
        switch reference.kind {
        case .remoteBranch:
            guard let remoteBranch = reference.remoteBranchComponents,
                  remoteBranch.branch != "HEAD",
                  model.remotes.contains(where: {
                      $0.name == remoteBranch.remote && $0.isGitHub
                  }) else { return nil }
            return reference

        case .localBranch:
            let candidates = model.references.filter { candidate in
                guard referenceIDsAtCommit.contains(candidate.id),
                      let remoteBranch = candidate.remoteBranchComponents,
                      remoteBranch.branch == reference.name else { return false }
                return model.remotes.contains {
                    $0.name == remoteBranch.remote && $0.isGitHub
                }
            }
            return candidates.sorted { lhs, rhs in
                let lhsOrigin = lhs.name.hasPrefix("origin/")
                let rhsOrigin = rhs.name.hasPrefix("origin/")
                if lhsOrigin != rhsOrigin { return lhsOrigin }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }.first

        case .tag, .other:
            return nil
        }
    }

    private var canMergeIntoCurrent: Bool {
        !reference.isHead
            && !commitIsHead
            && model.branch != "detached HEAD"
    }

    private var rebaseTargets: [GitReference] {
        guard reference.kind == .localBranch,
              !reference.isRemoteDefaultBranch(in: model.references) else { return [] }
        return model.references
            .filter {
                ($0.kind == .localBranch || $0.kind == .remoteBranch)
                    && !referenceIDsAtCommit.contains($0.id)
                    && !$0.name.hasSuffix("/HEAD")
            }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return lhs.kind == .localBranch
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private var localRebaseTargets: [GitReference] {
        rebaseTargets.filter { $0.kind == .localBranch }
    }

    private var remoteRebaseTargets: [GitReference] {
        rebaseTargets.filter { $0.kind == .remoteBranch }
    }

    private var operationsDisabled: Bool {
        model.isBusy
            || model.isGeneratingCommitMessage
            || model.hasPendingChangeOperations
    }

    private func copyReferenceName() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reference.name, forType: .string)
    }
}

struct BranchPill: View {
    @EnvironmentObject private var model: RepositoryModel
    let reference: GitReference
    var syncedRemotes: [GitReference] = []
    let commitIsHead: Bool
    let referenceIDsAtCommit: Set<String>

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
            } else {
                BranchGlyph(size: 12, color: foregroundColor)
            }
            Text(reference.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if !syncedRemotes.isEmpty {
                Image(systemName: "cloud")
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 8)
        .frame(height: 21)
        .frame(maxWidth: 130)
        // Hug the label: cap long names at 130, but never expand past the
        // content's ideal width and never compress the label away.
        .fixedSize(horizontal: true, vertical: false)
        .background(backgroundColor, in: Capsule())
        .help(helpText)
        .contextMenu {
            ReferenceContextMenuItems(
                reference: reference,
                commitIsHead: commitIsHead,
                referenceIDsAtCommit: referenceIDsAtCommit
            )

            if !syncedRemotes.isEmpty {
                Divider()

                ForEach(syncedRemotes) { remote in
                    Menu(remote.name) {
                        ReferenceContextMenuItems(
                            reference: remote,
                            commitIsHead: commitIsHead,
                            referenceIDsAtCommit: referenceIDsAtCommit
                        )
                    }
                }
            }
        }
    }

    /// Local branches use the git-branch glyph (rendered when `symbol` is
    /// nil); remote, tag, and other refs keep their SF Symbols.
    private var symbol: String? {
        switch reference.kind {
        case .localBranch: return nil
        case .remoteBranch: return "cloud"
        case .tag: return "tag"
        case .other: return "bookmark"
        }
    }

    private var foregroundColor: Color {
        isCurrentReference ? AppTheme.onPill : AppTheme.primary
    }

    private var backgroundColor: Color {
        guard isCurrentReference else { return AppTheme.graphReferenceBackground }

        // Mirrors VS Code's source-control graph: the current branch pill and
        // its graph lane share one color (charts.blue), the upstream pill and
        // lane another (charts.purple).
        return isCurrentRemoteReference ? AppTheme.graphRemote : AppTheme.graphBlue
    }

    private var isCurrentReference: Bool {
        if reference.isHead { return true }
        return isCurrentRemoteReference
    }

    private var isCurrentRemoteReference: Bool {
        reference.id == model.upstreamReference?.id
    }

    private var helpText: String {
        switch reference.kind {
        case .localBranch:
            let base = reference.isHead
                ? "Current local branch: \(reference.name)"
                : "Local branch: \(reference.name)"
            guard !syncedRemotes.isEmpty else { return base }
            let names = syncedRemotes.map(\.name).joined(separator: ", ")
            return "\(base), in sync with \(names)"
        case .remoteBranch:
            return "Remote branch: \(reference.name)"
        case .tag:
            return "Tag: \(reference.name)"
        case .other:
            return reference.name
        }
    }
}

extension GraphLaneColor {
    var swiftUIColor: Color {
        switch self {
        case .current: return AppTheme.graphBlue
        case .remote: return AppTheme.graphRemote
        case .base: return AppTheme.graphLane(0xD19A66)
        case .lane1: return AppTheme.graphLane(0xE5C07B)
        case .lane2: return AppTheme.graphLane(0xE06C75)
        case .lane3: return AppTheme.graphLane(0x98C379)
        case .lane4: return AppTheme.graphLane(0x56B6C2)
        case .lane5: return AppTheme.graphLane(0x528BFF)
        }
    }

    var nsColor: NSColor { NSColor(swiftUIColor) }
}

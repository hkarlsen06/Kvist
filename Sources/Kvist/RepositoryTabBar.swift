import AppKit
import SwiftUI

struct RepositoryTopBar: View {
    @EnvironmentObject private var tabsModel: WorkspaceTabsModel
    @State private var pendingTabScroll: DispatchWorkItem?
    @StateObject private var dragState = TabDragState<UUID>()

    /// Coordinate space of the whole bar; tab frames are reported in it so
    /// the AppKit drag area behind the bar can hit-test tabs for ⌘-drag.
    static let coordinateSpaceName = "repositoryTopBar"

    // Leading inset that clears the traffic lights now that the bar sits in
    // the titlebar region of the full-size-content window.
    private let trafficLightInset: CGFloat = 78

    var body: some View {
        HStack(spacing: 4) {
            // When the tabs fit, hug their content so the leftover width is
            // empty (and therefore draggable via WindowDragArea); fall back to
            // the scrolling strip only on overflow.
            if tabsModel.topLevelTabs.count <= 3 {
                HStack(spacing: 3) {
                    tabItems
                }
            } else {
                scrollingTabs
            }

            Button {
                tabsModel.addTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.secondary)
            .accessibilityLabel("New Repository Tab")
            .help("New Repository Tab (⌘T)")

            Spacer(minLength: 4)
        }
        .padding(.leading, trafficLightInset)
        .padding(.trailing, 4)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .coordinateSpace(name: Self.coordinateSpaceName)
        // The hairline under the strip is lighter than the canvas, so it
        // reads as the panel's top edge rather than as the bar casting shade.
        // The active tab covers it and continues it with its outline, which
        // keeps the tab and the panel one front surface.
        .backgroundPreferenceValue(TabFramesPreferenceKey.self) { frames in
            WindowDragArea(
                orderedTabIDs: tabsModel.topLevelTabs.map(\.id),
                tabFrames: frames,
                dragState: dragState,
                selectTab: { tabsModel.select($0) },
                // The strip already renders drag-shifted positions, so the
                // committed order change must not animate: the reordered
                // layout lands exactly where the tabs are drawn.
                moveTab: { tabID, index in
                    tabsModel.moveTab(tabID, toIndex: index)
                }
            )
        }
        .background(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.tabOutline)
                .frame(height: 1)
        }
        .background(AppTheme.tabStripFill)
        // Confine the active tab's shadow to the bar so it never smudges the
        // panel below the divider, where the tab merges with the content.
        .clipped()
    }

    private var tabItems: some View {
        ForEach(tabsModel.topLevelTabs) { tab in
            RepositoryTabItem(
                tab: tab,
                isActive: tab.id == tabsModel.activeTabID,
                dragState: dragState
            )
            .id(tab.id)
        }
    }

    private var scrollingTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 3) {
                    tabItems
                }
            }
            // `.hidden` can still show a legacy scroller when a mouse is used.
            .scrollIndicators(.never)
            // The strip's bottom hairline stays sharp under the blur.
            .modifier(HorizontalScrollEdgeBlur(fill: AppTheme.tabStripFill, bottomInset: 1))
            .onChange(of: tabsModel.activeTabID) {
                pendingTabScroll?.cancel()
                let tabID = tabsModel.activeTabID
                let workItem = DispatchWorkItem {
                    proxy.scrollTo(tabID, anchor: .center)
                    pendingTabScroll = nil
                }
                pendingTabScroll = workItem
                let delayMilliseconds = KvistPerformanceInstrumentation.configuration?.mode
                    == .tabs ? 2_000 : 100
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + .milliseconds(delayMilliseconds),
                    execute: workItem
                )
            }
            // A restored active tab can sit past the strip's edge at launch.
            .onAppear { proxy.scrollTo(tabsModel.activeTabID, anchor: .center) }
            .onDisappear { pendingTabScroll?.cancel() }
        }
    }
}

/// Live state of an in-progress tab drag. The event monitor in
/// `WindowDragArea` writes to it; the tab items read it to render the dragged
/// tab under the pointer and slide its neighbors aside. The checkout bar
/// uses it too, driven by a drag gesture. The model's order is
/// untouched until the drop, so the layout (and the tab frames captured at
/// drag start) stays stable for the whole gesture.
@MainActor
final class TabDragState<ID: Hashable>: ObservableObject {
    @Published private(set) var draggedTabID: ID?
    @Published private(set) var pointerX: CGFloat = 0
    private var grabOffsetX: CGFloat = 0
    private var frames: [ID: CGRect] = [:]
    private var order: [ID] = []

    /// Spacing of the strip's HStack; a neighbor making room for the
    /// dragged tab moves by the tab's width plus this.
    private let stripSpacing: CGFloat

    init(stripSpacing: CGFloat = 3) {
        self.stripSpacing = stripSpacing
    }

    var isDragging: Bool { draggedTabID != nil }

    func begin(
        tabID: ID,
        pointerX: CGFloat,
        frames: [ID: CGRect],
        order: [ID]
    ) {
        guard let frame = frames[tabID] else { return }
        self.frames = frames
        self.order = order
        grabOffsetX = pointerX - frame.minX
        self.pointerX = pointerX
        draggedTabID = tabID
    }

    func update(pointerX: CGFloat) {
        guard isDragging else { return }
        self.pointerX = pointerX
    }

    func end() {
        draggedTabID = nil
        frames = [:]
        order = []
    }

    /// Index the dragged tab would land at if dropped now: the number of
    /// other tabs whose midpoint sits left of the dragged tab's visual
    /// center. In the lazy scrolling strip, tabs scrolled out of view report
    /// no frame; those before the first laid-out tab are to the left, so
    /// they count toward the index as well.
    var targetIndex: Int {
        guard let draggedTabID,
              let draggedFrame = frames[draggedTabID] else { return 0 }
        let center = pointerX - grabOffsetX + draggedFrame.width / 2
        let others = order.filter { $0 != draggedTabID }
        let hiddenLeadingCount = others.firstIndex {
            frames[$0] != nil
        } ?? others.count
        return hiddenLeadingCount + others
            .compactMap { frames[$0]?.midX }
            .count { $0 < center }
    }

    /// Visual x-offset for a tab while a drag is in progress. The dragged
    /// tab tracks the pointer; a neighbor shifts one slot when it is between
    /// the dragged tab's original index and its current target index.
    func offsetX(for tabID: ID) -> CGFloat {
        guard let draggedTabID,
              let draggedFrame = frames[draggedTabID],
              let draggedIndex = order.firstIndex(of: draggedTabID) else {
            return 0
        }
        if tabID == draggedTabID {
            // Keep the dragged tab inside the strip even when the pointer
            // overshoots it.
            let stripMinX = frames.values.map(\.minX).min() ?? draggedFrame.minX
            let stripMaxX = frames.values.map(\.maxX).max() ?? draggedFrame.maxX
            let desiredLeft = min(
                max(pointerX - grabOffsetX, stripMinX),
                stripMaxX - draggedFrame.width
            )
            return desiredLeft - draggedFrame.minX
        }
        guard let index = order.firstIndex(of: tabID) else { return 0 }
        let slot = draggedFrame.width + stripSpacing
        let othersIndex = index > draggedIndex ? index - 1 : index
        let makesRoom: CGFloat = othersIndex >= targetIndex ? slot : 0
        let alreadyAfter: CGFloat = othersIndex >= draggedIndex ? slot : 0
        return makesRoom - alreadyAfter
    }
}

/// Transparent view behind the tab row's content that restores the standard
/// titlebar behaviors, window dragging and double-click zoom or minimize, for
/// the empty areas of the bar, since it now occupies the titlebar region.
///
/// It also implements drag-to-reorder for the tabs. That cannot live in the
/// SwiftUI layer or in an AppKit subview: the hosting hierarchy swallows
/// modified clicks before they reach tab buttons, gestures, or any overlay's
/// `hitTest`, and a drag that begins on a button belongs to that button. A
/// local event monitor sees every event ahead of dispatch: presses on a tab
/// pass through untouched (so click-to-select and the close button keep
/// working), and once the pointer moves past a small threshold the monitor
/// claims the rest of the sequence and drives `TabDragState`. This view
/// spans the whole bar, so converting event locations into its (flipped)
/// bounds yields the same coordinates as the tab frames reported in the
/// bar's named coordinate space. Both use one coordinate system, converted
/// by AppKit alone.
struct WindowDragArea: NSViewRepresentable {
    var orderedTabIDs: [UUID]
    var tabFrames: [UUID: CGRect]
    var dragState: TabDragState<UUID>
    var selectTab: (UUID) -> Void
    var moveTab: (UUID, Int) -> Void

    final class DragView: NSView {
        var orderedTabIDs: [UUID] = []
        var tabFrames: [UUID: CGRect] = [:]
        var dragState: TabDragState<UUID>?
        var selectTab: ((UUID) -> Void)?
        var moveTab: ((UUID, Int) -> Void)?
        private var reorderMonitor: Any?
        private var pendingTabID: UUID?
        private var pendingStartX: CGFloat = 0

        /// Horizontal movement, in points, that turns a press on a tab into
        /// a reorder drag instead of a click.
        private let dragThreshold: CGFloat = 4

        // Match SwiftUI's top-left-origin coordinates so event locations can
        // be compared against the tab frames from the bar's named space.
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            teardownMonitor()
            guard window != nil else { return }
            reorderMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                self?.handleReorder(event) ?? event
            }
        }

        deinit {
            teardownMonitor()
        }

        private func teardownMonitor() {
            if let reorderMonitor {
                NSEvent.removeMonitor(reorderMonitor)
            }
            reorderMonitor = nil
            pendingTabID = nil
        }

        /// Tracks presses on tabs; consumes the mouse sequence only once a
        /// drag is in progress, returning every other event unchanged.
        private func handleReorder(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            let pointerX = convert(event.locationInWindow, from: nil).x
            switch event.type {
            case .leftMouseDown:
                guard let tabID = tabID(at: event) else { return event }
                pendingTabID = tabID
                pendingStartX = pointerX
                return event
            case .leftMouseDragged:
                if let dragState, dragState.isDragging {
                    dragState.update(pointerX: pointerX)
                    return nil
                }
                guard let pendingTabID,
                      abs(pointerX - pendingStartX) >= dragThreshold else {
                    return event
                }
                // The grabbed tab activates, matching a plain click.
                selectTab?(pendingTabID)
                dragState?.begin(
                    tabID: pendingTabID,
                    pointerX: pointerX,
                    frames: tabFrames,
                    order: orderedTabIDs
                )
                self.pendingTabID = nil
                return nil
            case .leftMouseUp:
                pendingTabID = nil
                guard let dragState, dragState.isDragging,
                      let draggedTabID = dragState.draggedTabID else {
                    return event
                }
                moveTab?(draggedTabID, dragState.targetIndex)
                dragState.end()
                // Swallow the up: the press passed through to the tab's
                // buttons, and completing it here could re-click whatever
                // ended under the pointer (notably the close button).
                return nil
            default:
                return event
            }
        }

        private func tabID(at event: NSEvent) -> UUID? {
            let local = convert(event.locationInWindow, from: nil)
            return orderedTabIDs.first { tabFrames[$0]?.contains(local) == true }
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize":
                    window.performMiniaturize(nil)
                case "None":
                    break
                default:
                    window.performZoom(nil)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: DragView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: DragView) {
        view.orderedTabIDs = orderedTabIDs
        view.tabFrames = tabFrames
        view.dragState = dragState
        view.selectTab = selectTab
        view.moveTab = moveTab
    }
}

/// Frames of each tab, keyed by tab ID, in the top bar's named coordinate
/// space. Reported by `RepositoryTabItem` and consumed by `WindowDragArea`
/// to hit-test tabs during ⌘-drag reordering.
struct TabFramesPreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(
        value: inout [UUID: CGRect],
        nextValue: () -> [UUID: CGRect]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Concave quarter-circle fillet drawn just outside the active tab's base so
/// its edges curve outward into the panel surface below (an "inverted" corner
/// radius, like browser tabs).
struct TabBaseFillet: Shape {
    var trailing = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if trailing {
            path.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addArc(
                center: CGPoint(x: rect.maxX, y: rect.minY), radius: rect.height,
                startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
            )
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addArc(
                center: CGPoint(x: rect.minX, y: rect.minY), radius: rect.height,
                startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

/// The active tab's silhouette without its base: up from the strip's bottom
/// hairline through the leading fillet, over the rounded top, and back down
/// through the trailing fillet. It draws past its rect by the fillet width.
struct ActiveTabOutline: Shape {
    private let radius: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        // Center the stroke on the strip's 1-point bottom hairline.
        let bottom = rect.maxY - 0.5
        var path = Path()
        path.move(to: CGPoint(x: rect.minX - radius, y: bottom))
        path.addArc(
            center: CGPoint(x: rect.minX - radius, y: bottom - radius), radius: radius,
            startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: bottom),
            radius: radius
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: bottom - radius))
        path.addArc(
            center: CGPoint(x: rect.maxX + radius, y: bottom - radius), radius: radius,
            startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true
        )
        return path
    }
}

struct RepositoryTabItem: View {
    @EnvironmentObject private var tabsModel: WorkspaceTabsModel
    @ObservedObject var tab: RepositoryTab
    @ObservedObject var dragState: TabDragState<UUID>
    let tabID: UUID
    let tabName: String
    let isActive: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(tab: RepositoryTab, isActive: Bool, dragState: TabDragState<UUID>) {
        _tab = ObservedObject(wrappedValue: tab)
        _dragState = ObservedObject(wrappedValue: dragState)
        tabID = tab.id
        // A worktree's tab is named after its repository's main worktree.
        tabName = tab.worktrees.first?.name ?? tab.displayName
        self.isActive = isActive
    }

    private var isDragged: Bool {
        dragState.draggedTabID == tabID
    }

    private var dragOffsetX: CGFloat {
        dragState.offsetX(for: tabID)
    }

    var body: some View {
        HStack(spacing: 1) {
            Button {
                tabsModel.select(tabID)
            } label: {
                HStack(spacing: 5) {
                    if tab.isSSH {
                        SSHLogo()
                            .frame(width: 14, height: 14)
                            .accessibilityHidden(true)
                    }

                    Text(tabName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // Hug the name instead of always expanding to the cap.
                        .frame(maxWidth: 140)
                        .fixedSize(horizontal: true, vertical: false)

                    if tab.hasChanges {
                        Circle()
                            .fill(AppTheme.modified)
                            .frame(width: 5, height: 5)
                            .accessibilityLabel("Has changes")
                    }
                }
                .padding(.leading, 9)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAction(named: "Close \(tabName) Tab") {
                tabsModel.close(tabID)
            }

            Button {
                tabsModel.close(tabID)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || isActive ? 1 : 0)
            .allowsHitTesting(hovering || isActive)
            .accessibilityHidden(!(hovering || isActive))
            .accessibilityLabel("Close \(tabName) Tab")
            .help(isActive ? "Close Tab (⌘W)" : "Close Tab")
            .padding(.trailing, 2)
        }
        .foregroundStyle(isActive ? AppTheme.primary : AppTheme.secondary)
        .frame(minWidth: 64)
        .frame(height: 24)
        // The active tab grows a skirt down to the bar's bottom edge and is
        // filled with the panel's canvas color, so it flows seamlessly into
        // the content below (the bar's divider is drawn beneath the tabs).
        // Its top edge also rises above the inactive tabs and it casts a soft
        // shadow, so it reads as sitting on top of the bar rather than inset.
        .padding(.top, isActive ? 3 : 0)
        .padding(.bottom, isActive ? 5 : 0)
        .background {
            if isActive {
                UnevenRoundedRectangle(cornerRadii: .init(
                    topLeading: 5, bottomLeading: 0, bottomTrailing: 0, topTrailing: 5
                ))
                .fill(AppTheme.canvas)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            } else if hovering {
                RoundedRectangle(cornerRadius: 5)
                    .fill(AppTheme.raisedFill)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if isActive {
                TabBaseFillet()
                    .fill(AppTheme.canvas)
                    .frame(width: 5, height: 5)
                    .offset(x: -5)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isActive {
                TabBaseFillet(trailing: true)
                    .fill(AppTheme.canvas)
                    .frame(width: 5, height: 5)
                    .offset(x: 5)
            }
        }
        .overlay {
            if isActive {
                ActiveTabOutline()
                    .stroke(AppTheme.tabOutline, lineWidth: 1)
            }
        }
        .padding(.bottom, isActive ? 0 : 5)
        .frame(height: 34, alignment: .bottom)
        // The offset comes before the frame-reporting background: modifiers
        // after .offset see the untranslated layout frame, so the reported
        // tab frames stay stable for hit-testing while the drag renders the
        // tab under the pointer.
        .offset(x: dragOffsetX)
        // Neighbors ease aside while a drag is in progress; the dragged tab
        // tracks the pointer directly. On drop everything changes in one
        // unanimated pass so the committed order lands exactly where the
        // tabs are already drawn.
        .animation(
            dragState.isDragging && !isDragged && !reduceMotion
                ? .easeInOut(duration: 0.13)
                : nil,
            value: dragOffsetX
        )
        .zIndex(isDragged ? 1 : 0)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TabFramesPreferenceKey.self,
                    value: [
                        tabID: proxy.frame(
                            in: .named(RepositoryTopBar.coordinateSpaceName)
                        )
                    ]
                )
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(
            tab.loadedModel?.sshRepository?.location()
                ?? tab.repositoryURL?.path
                ?? "Open a repository"
        )
        .contextMenu {
            Button("Close Tab") {
                tabsModel.close(tabID)
            }

            Button("Close Other Tabs") {
                tabsModel.closeOthers(tabID)
            }
            .disabled(tabsModel.topLevelTabs.count < 2)

            if let url = tab.repositoryURL {
                let sshRepository = SSHRepository.mirrored(at: url)
                Divider()

                if sshRepository == nil {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }

                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        sshRepository?.location() ?? url.path,
                        forType: .string
                    )
                }
            }
        }
    }
}

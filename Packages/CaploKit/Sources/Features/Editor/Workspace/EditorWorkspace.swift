import AppKit
import SwiftUI
import Observation
import EditingCore
import CaploDesignSystem

/// 预览与时间线的工作区：一个原生 `NSSplitView`，上窗格是成片显示面，下窗格是时间线（顶部固定高度的
/// SwiftUI 工具栏 + 原生视口）。分界由 AppKit 拖动，两个窗格都是图层视图，尺寸在同一事务内改变，
/// 拖动期间没有任何 SwiftUI 重新布局；模型变化通过观察推送给视口，而不是靠 SwiftUI 刷新。
struct EditorWorkspace: NSViewRepresentable {
    @Environment(\.caploMaterialOpaquePreview) private var materialOpaquePreview
    @Environment(\.caploMaterialHighContrastPreview) private var materialHighContrastPreview
    @Environment(\.colorSchemeContrast) private var materialContrast
    let model: VideoEditorModel
    let viewport: TimelineViewport
    let addFocus: () -> Void

    func makeNSView(context: Context) -> EditorWorkspaceView {
        let view = EditorWorkspaceView(model: model, viewport: viewport, addFocus: addFocus)
        view.updateMaterialPreview(opaque: materialOpaquePreview, contrast: previewContrast)
        return view
    }

    func updateNSView(_ view: EditorWorkspaceView, context: Context) {
        view.updateMaterialPreview(opaque: materialOpaquePreview, contrast: previewContrast)
    }

    private var previewContrast: ColorSchemeContrast {
        materialHighContrastPreview.map { $0 ? .increased : .standard } ?? materialContrast
    }

    static func dismantleNSView(_ view: EditorWorkspaceView, coordinator: ()) { view.tearDown() }
}

@MainActor
final class EditorWorkspaceView: NSSplitView, NSSplitViewDelegate {
    static let dividerSize: CGFloat = CaploMetrics.Spacing.s
    static let minimumCanvasHeight: CGFloat = 220
    static let minimumTimelineHeight: CGFloat = 180
    static let defaultTimelineHeight: CGFloat = 294
    static let heightKey = "editor.timelineHeight"

    private let model: VideoEditorModel
    let viewport: TimelineViewport
    let canvasPane = NSView(frame: .zero)
    let canvas = CanvasSurfaceView(frame: .zero)
    private let overlay: NSHostingView<AnyView>
    /// 遮罩与文字的编辑层夹在成片显示面和空态提示之间；不在对应面板时它们的 hitTest 一律放行。
    private let maskEditor: MaskCanvasView
    private let textEditor: TextCanvasView
    private let overlayContent: AnyView
    private var materialOpaquePreview: Bool?
    private var materialContrast: ColorSchemeContrast = .standard
    let timelinePane: TimelinePaneView
    private var detached = false
    private var appliedStoredHeight = false
    private var defaultsObserver: NSObjectProtocol?
    private var persistWork: DispatchWorkItem?

    init(model: VideoEditorModel, viewport: TimelineViewport, addFocus: @escaping () -> Void) {
        self.model = model; self.viewport = viewport
        overlayContent = AnyView(CanvasOverlay(model: model))
        let overlayHost = TransparentEditorHostingView(rootView: overlayContent)
        // 空态与载入提示是纯装饰，必须放行点击，否则它下面的遮罩 / 文字编辑层收不到任何鼠标。
        overlayHost.passesThroughClicks = true
        overlay = overlayHost
        maskEditor = MaskCanvasView(model: model, canvas: canvas)
        textEditor = TextCanvasView(model: model, canvas: canvas)
        timelinePane = TimelinePaneView(model: model, viewport: viewport, addFocus: addFocus)
        super.init(frame: .zero)
        isVertical = false
        dividerStyle = .thin
        delegate = self
        wantsLayer = true
        // 分界留白透出编辑器根材质，不能再用不透明实色把窗口层遮住。
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false

        canvasPane.wantsLayer = true
        canvasPane.layer?.cornerRadius = CaploMetrics.Radius.panel
        canvasPane.layer?.masksToBounds = true
        canvasPane.layer?.borderWidth = CaploMetrics.hairline
        canvasPane.layer?.borderColor = EditorMaterialDrawing.color(CaploNSColor.glassEdge, appearance: effectiveAppearance)
        canvas.presenter = model.canvas
        canvas.snapshotMode = model.canvas.snapshotMode
        model.canvas.view = canvas
        canvas.autoresizingMask = [.width, .height]
        overlay.sizingOptions = []
        overlay.autoresizingMask = [.width, .height]
        canvasPane.addSubview(canvas)
        maskEditor.autoresizingMask = [.width, .height]
        canvasPane.addSubview(maskEditor)
        textEditor.autoresizingMask = [.width, .height]
        canvasPane.addSubview(textEditor)
        canvasPane.addSubview(overlay)
        addArrangedSubview(canvasPane)
        addArrangedSubview(timelinePane)
        // 窗口变高变矮时只让预览伸缩，时间线保持用户设定的高度。
        setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 250), forSubviewAt: 0)
        setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 750), forSubviewAt: 1)

        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.storedHeightChanged() }
        }
        observeModel()
    }
    required init?(coder: NSCoder) { fatalError("不支持归档初始化") }

    /// 审核意图穿过 NSViewRepresentable 与独立 HostingView；生产 nil 保持系统偏好。
    func updateMaterialPreview(opaque: Bool?, contrast: ColorSchemeContrast) {
        guard opaque != materialOpaquePreview || contrast != materialContrast else { return }
        materialOpaquePreview = opaque; materialContrast = contrast
        canvas.materialOpaqueOverride = opaque
        timelinePane.updateMaterialPreview(opaque: opaque, contrast: contrast)
        let content = overlayContent
        if let opaque {
            overlay.rootView = AnyView(content.caploMaterialAccessibilityPreview(reduceTransparency: opaque, highContrast: contrast == .increased))
        } else { overlay.rootView = content }
    }

    func tearDown() {
        detached = true
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        persistWork?.cancel()
        timelinePane.timeline.detach()
        if model.canvas.view === canvas { model.canvas.view = nil }
    }

    // MARK: 模型 → 视口

    /// 模型或视口参数变化时把最新状态推给时间线视口与显示面；视口自己只在输入真的变化时重绘。
    private func observeModel() {
        guard !detached else { return }
        withObservationTracking {
            timelinePane.timeline.update(edit: model.edit, analysis: model.analysis, selection: model.selectedClipIDs,
                                         primary: model.selectedClip, focus: model.selectedFocus, mask: model.selectedMask, text: model.selectedText, caption: model.selectedCaption,
                                         zoom: viewport.zoom, fit: viewport.fitRequest, heights: viewport.trackHeights,
                                         reveal: model.revealRequest)
            canvas.aspectRatio = model.edit.layout.ratio.value
            canvas.isHiddenContent = (model.edit.duration <= 0)
            // 遮罩框跟着编辑内容、播放头与选中项走；播放中整层不画，所以顺带读一下 playing。
            maskEditor.refreshFor(edit: model.edit, time: model.skimPosition ?? model.position,
                                  selection: model.selectedMask, editing: model.maskEditing, playing: model.playing)
            textEditor.refreshFor(edit: model.edit, time: model.skimPosition ?? model.position,
                                  selection: model.editingTextID, editing: model.textEditing, playing: model.playing)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeModel() }
        }
    }

    // MARK: 分界

    override var dividerThickness: CGFloat { Self.dividerSize }

    override var isOpaque: Bool { false }

    override func drawDivider(in rect: NSRect) {
        let handle = CGRect(x: rect.midX - 18, y: rect.midY - 1.5, width: 36, height: 3)
        CaploNSColor.textTertiary.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: handle, xRadius: 1.5, yRadius: 1.5).fill()
    }

    /// 分界拖动在 AppKit 的跟踪循环里完成：时间线按当前尺寸刷新可见行，松手后才记住高度。
    override func mouseDown(with event: NSEvent) {
        timelinePane.timeline.liveResizing = true
        viewport.liveResizing = true
        super.mouseDown(with: event)
        viewport.liveResizing = false
        timelinePane.timeline.liveResizing = false
        persistHeight(now: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        canvasPane.layer?.borderColor = EditorMaterialDrawing.color(CaploNSColor.glassEdge, appearance: effectiveAppearance)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if !appliedStoredHeight, bounds.height > 0 {
            appliedStoredHeight = true
            applyStoredHeight()
        }
    }

    var timelineHeight: CGFloat { timelinePane.frame.height }

    private var clampedStoredHeight: CGFloat {
        let stored = UserDefaults.standard.object(forKey: Self.heightKey) as? Double ?? Double(Self.defaultTimelineHeight)
        let value = stored.isFinite ? CGFloat(stored) : Self.defaultTimelineHeight
        let maximum = max(Self.minimumTimelineHeight, bounds.height - dividerThickness - Self.minimumCanvasHeight)
        return min(maximum, max(Self.minimumTimelineHeight, value))
    }

    private func applyStoredHeight() {
        guard bounds.height > 0 else { return }
        setPosition(bounds.height - dividerThickness - clampedStoredHeight, ofDividerAt: 0)
    }

    /// 偏好被外部改写（设置页或测试）时同步分界；自己写入的值与当前一致，不会来回触发。
    private func storedHeightChanged() {
        guard !detached, bounds.height > 0, abs(clampedStoredHeight - timelineHeight) > 0.5 else { return }
        applyStoredHeight()
    }

    private func persistHeight(now: Bool) {
        persistWork?.cancel()
        let height = Double(timelineHeight)
        let work = DispatchWorkItem { UserDefaults.standard.set(height, forKey: Self.heightKey) }
        persistWork = work
        if now { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work) }
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, Self.minimumCanvasHeight)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, bounds.height - dividerThickness - Self.minimumTimelineHeight)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard appliedStoredHeight else { return }
        persistHeight(now: false)
    }
}

/// 时间线窗格：顶部固定 44 点的 SwiftUI 工具栏、1 点分隔线、其余是原生视口。子视图在尺寸变化时同步摆放。
@MainActor
final class TimelinePaneView: NSView {
    let timeline: TimelineViewportView
    private let toolbar: NSHostingView<AnyView>
    private let toolbarContent: AnyView
    private let separator = NSBox()

    init(model: VideoEditorModel, viewport: TimelineViewport, addFocus: @escaping () -> Void) {
        timeline = TimelineViewportView(model: model, viewport: viewport)
        toolbarContent = AnyView(TimelineToolbar(model: model, viewport: viewport, addFocus: addFocus)
            .background(CaploMaterialBackground(.canvas)).tint(CaploColor.accent))
        toolbar = TransparentEditorHostingView(rootView: toolbarContent)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CaploMetrics.Radius.panel
        layer?.masksToBounds = true
        layer?.borderWidth = CaploMetrics.hairline
        layer?.borderColor = EditorMaterialDrawing.color(CaploNSColor.glassEdge, appearance: effectiveAppearance)
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        toolbar.sizingOptions = []
        separator.boxType = .separator
        addSubview(timeline)
        addSubview(separator)
        addSubview(toolbar)
        place()
    }
    required init?(coder: NSCoder) { fatalError("不支持归档初始化") }

    func updateMaterialPreview(opaque: Bool?, contrast: ColorSchemeContrast) {
        timeline.materialOpaqueOverride = opaque
        let content = toolbarContent
        if let opaque {
            toolbar.rootView = AnyView(content.caploMaterialAccessibilityPreview(reduceTransparency: opaque, highContrast: contrast == .increased))
        } else { toolbar.rootView = content }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) { place() }

    private func place() {
        let toolbarHeight = CaploMetrics.toolbarHeight
        toolbar.frame = CGRect(x: 0, y: bounds.height - toolbarHeight, width: bounds.width, height: toolbarHeight)
        separator.frame = CGRect(x: 0, y: bounds.height - toolbarHeight - 1, width: bounds.width, height: 1)
        timeline.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - toolbarHeight - 1))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = EditorMaterialDrawing.color(CaploNSColor.glassEdge, appearance: effectiveAppearance)
    }
}

/// 独立工具栏与空态宿主不提供额外窗口底色；玻璃由主窗口和显式表面共同合成。
private final class TransparentEditorHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    /// 纯装饰的浮层设成 true：`NSHostingView` 即使根视图整棵 `allowsHitTesting(false)`，
    /// 命中测试仍会把自己交出去，压在它下面的画布编辑层就一次点击都收不到。
    var passesThroughClicks = false
    override func hitTest(_ point: NSPoint) -> NSView? { passesThroughClicks ? nil : super.hitTest(point) }
    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError("不支持归档初始化") }
}

/// 预览窗格上的空态与载入提示；帧数据不经 SwiftUI，这里只有两种覆盖状态。
struct CanvasOverlay: View {
    let model: VideoEditorModel
    var body: some View {
        ZStack {
            if (model.edit.duration <= 0) {
                ContentUnavailableView("时间线为空", systemImage: "film", description: Text("撤销删除以恢复片段。"))
            }
            if model.loading {
                ProgressView("载入画面…").padding(CaploMetrics.Spacing.l)
                    .caploMaterial(.raised, cornerRadius: CaploMetrics.Radius.card)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

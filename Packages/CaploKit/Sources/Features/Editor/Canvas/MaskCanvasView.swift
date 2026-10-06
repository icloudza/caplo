import AppKit
import CaploDesignSystem
import EditingCore
import RenderKit

/// 画布上的遮罩编辑层：画出当前时刻生效的遮罩框，拖块体移动、拖八个把手改大小。
///
/// 只在遮罩面板打开时活着（`model.maskEditing`），而且 `hitTest` 只在遮罩框或把手上返回自己，
/// 其余位置一律放行。播放中整层隐藏——那时用户不是在调框，每帧重画矢量框是白费的。
@MainActor
final class MaskCanvasView: NSView {
    private let model: VideoEditorModel
    /// 成片显示面；遮罩框的坐标基准是它的 `videoRect`。
    private weak var canvas: CanvasSurfaceView?
    /// 一次拖动的快照：按下时记住原矩形与按下点，每一步都从快照重算，不累积误差。
    private struct Drag {
        let id: UUID
        let handle: MaskCanvasMath.Handle
        let origin: CGPoint
        let rect: CGRect
        var moved = false
    }
    private var drag: Drag?
    private var hovered: MaskCanvasMath.Handle?
    private static let handleSize: CGFloat = 9
    /// 把手的命中范围比画出来的大一圈，细框也好抓。
    private static let handleHitSlop: CGFloat = 5

    init(model: VideoEditorModel, canvas: CanvasSurfaceView) {
        self.model = model; self.canvas = canvas
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError("不支持归档初始化") }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 当前状态

    /// 画面层已经被全屏文字淡到看不见时不接管画布：那时框画在一片空背景上，
    /// 既看不出遮的是什么，还把点击吞掉。
    private var active: Bool {
        model.maskEditing && !model.playing && !model.edit.maskList.isEmpty && stageTransform.alpha > 0.05
    }
    private var time: Double { model.skimPosition ?? model.position }
    private var sourceSize: CGSize {
        let full = model.entry.document.capture?.pixelSize ?? CGSize(width: 1920, height: 1080)
        return SceneRenderer.croppedSourceSize(full.width > 0 && full.height > 0 ? full : CGSize(width: 1920, height: 1080), layout: model.edit.layout)
    }
    /// 相机必须和画面完全同源：跟随镜头已预编译成运镜路径（renderEdit），
    /// 而且坐标已经换算到裁切区域（cropResolved）——少任何一步，
    /// 聚焦一推近编辑框就和真正被遮住的区域分家。
    private var focusState: FocusState { SceneEvaluator.focus(edit: model.renderEdit.cropResolved(), time: time) }
    /// 全屏文字 / 卡片 / 分屏时画面层被整体缩放挪位，编辑框也要跟着。
    private var stageTransform: StageTransform { model.edit.stage(at: time) }

    /// 当前时刻该画的遮罩，从下到上；每项带它在视图里的外接矩形。
    private func visible() -> [(id: UUID, mask: MaskSegment, state: MaskState, rect: CGRect)] {
        guard let videoRect = canvas?.videoRect, videoRect.width > 1 else { return [] }
        let focus = focusState, size = sourceSize, stage = stageTransform
        let spans = model.edit.maskSpans()
        var result: [(UUID, MaskSegment, MaskState, CGRect)] = []
        for mask in model.edit.maskList {
            guard let state = model.edit.maskState(mask, at: time, spans: spans) else { continue }
            guard let rect = MaskCanvasMath.viewRect(center: CGPoint(x: state.x, y: state.y),
                                                     size: CGSize(width: state.width, height: state.height),
                                                     videoRect: convert(videoRect, from: canvas), edit: model.edit,
                                                     sourceSize: size, focus: focus, stage: stage) else { continue }
            result.append((mask.id, mask, state, rect))
        }
        return result
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> MaskCanvasMath.Handle? {
        let reach = MaskCanvasMath.handleReach(rect, size: Self.handleSize, slop: Self.handleHitSlop)
        for handle in MaskCanvasMath.Handle.allCases where handle != .body {
            let anchor = handle.anchor
            let center = CGPoint(x: rect.minX + rect.width * anchor.x, y: rect.maxY - rect.height * anchor.y)
            if abs(point.x - center.x) <= reach && abs(point.y - center.y) <= reach { return handle }
        }
        return rect.insetBy(dx: -2, dy: -2).contains(point) ? .body : nil
    }

    /// 命中：选中的遮罩优先（它的把手要压过别的框），然后是从上往下的其他遮罩。
    private func target(at point: CGPoint) -> (id: UUID, handle: MaskCanvasMath.Handle, rect: CGRect)? {
        let items = visible()
        if let selected = model.selectedMask, let item = items.first(where: { $0.id == selected }),
           let handle = handle(at: point, in: item.rect) { return (item.id, handle, item.rect) }
        for item in items.reversed() where item.id != model.selectedMask {
            if item.rect.insetBy(dx: -2, dy: -2).contains(point) { return (item.id, .body, item.rect) }
        }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard active else { return nil }
        let local = convert(point, from: superview)
        return target(at: local) == nil ? nil : self
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard active, let hit = target(at: point) else { return }
        if model.selectedMask != hit.id {
            model.select(.mask(hit.id))
            needsDisplay = true
            // 刚点中的是别的遮罩：这一下只做选中，避免误拖。
            if hit.handle == .body { return }
        }
        guard let mask = model.edit.mask(id: hit.id) else { return }
        drag = Drag(id: hit.id, handle: hit.handle, origin: point,
                    rect: CGRect(x: mask.x - mask.width / 2, y: mask.y - mask.height / 2, width: mask.width, height: mask.height))
    }

    override func mouseDragged(with event: NSEvent) {
        guard var current = drag, let videoRect = canvas?.videoRect else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !current.moved, hypot(point.x - current.origin.x, point.y - current.origin.y) < 2 { return }
        current.moved = true; drag = current
        let rect = convert(videoRect, from: canvas)
        let focus = focusState, size = sourceSize, stage = stageTransform
        guard let now = MaskCanvasMath.normalized(point, videoRect: rect, edit: model.edit, sourceSize: size, focus: focus, stage: stage),
              let start = MaskCanvasMath.normalized(current.origin, videoRect: rect, edit: model.edit, sourceSize: size, focus: focus, stage: stage) else { return }
        model.beginInteraction()
        let next: CGRect
        if current.handle == .body {
            next = current.rect.offsetBy(dx: now.x - start.x, dy: now.y - start.y)
        } else {
            // 关键帧存在时，拖动改的是基础几何；否则拖出来的形状会被第一个关键帧立刻覆盖掉。
            next = MaskCanvasMath.resize(current.rect, handle: current.handle, to: now)
        }
        let parts = MaskCanvasMath.components(next)
        var edit = model.edit
        edit.updateMask(id: current.id) { mask in
            mask.x = parts.x; mask.y = parts.y; mask.width = parts.width; mask.height = parts.height
            mask.positionKeys = nil; mask.sizeKeys = nil
        }
        if model.edit != edit { model.edit = edit; model.previewChanged() }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; needsDisplay = true }
        // 没动过就没调用 beginInteraction，这里什么都不做，别把别处正在进行的交互撤掉。
        guard drag?.moved == true else { return }
        model.endInteraction()
    }

    override func mouseMoved(with event: NSEvent) {
        guard active else { return }
        let next = target(at: convert(event.locationInWindow, from: nil))?.handle
        guard next != hovered else { return }
        hovered = next; needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard active else { return }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        switch hovered {
        case .body: NSCursor.openHand.set()
        case .some: NSCursor.crosshair.set()
        case nil: super.cursorUpdate(with: event)
        }
    }

    /// 按 Esc 取消正在进行的拖动。
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53, drag != nil else { super.keyDown(with: event); return }
        model.cancelInteraction(); drag = nil; needsDisplay = true
    }

    // MARK: 绘制

    /// 工作区在观察事务里调用；参数就是这一层依赖的全部模型状态，
    /// 传进来是为了让 `withObservationTracking` 明确登记这几项，少一项遮罩框就会停在旧位置。
    func refreshFor(edit: VideoEdit, time: Double, selection: UUID?, editing: Bool, playing: Bool) {
        let state = State(edit: edit, time: time, selection: selection, editing: editing, playing: playing)
        guard state != applied else { return }
        let wasActive = applied?.isActive ?? false
        applied = state
        // 编辑层跟着画面一起淡：全屏文字把画面淡出的那 0.35 秒里，框不该"啪"地一下消失。
        // （淡到 0.05 以下就彻底停手，见 `active`。）
        alphaValue = min(1, max(0, edit.stage(at: time).alpha))
        needsDisplay = true
        if wasActive != state.isActive { updateTrackingAreas(); if !state.isActive { hovered = nil } }
    }
    private struct State: Equatable {
        let edit: VideoEdit
        let time: Double
        let selection: UUID?
        let editing: Bool
        let playing: Bool
        // 与 `active` 同一条判定：画面被全屏文字淡没了就不接管画布。
        var isActive: Bool { editing && !playing && !edit.maskList.isEmpty && edit.stage(at: time).alpha > 0.05 }
    }
    private var applied: State?

    override func draw(_ dirtyRect: NSRect) {
        guard active else { return }
        let selected = model.selectedMask
        for item in visible() {
            let isSelected = item.id == selected
            let color = item.state.kind == .highlight ? CaploNSColor.warning : CaploNSColor.mask
            let path = item.mask.shape == .ellipse ? NSBezierPath(ovalIn: item.rect) : NSBezierPath(roundedRect: item.rect, xRadius: 3, yRadius: 3)
            // 未选中的遮罩只留一条虚线，看得见但不抢注意力；选中的画实线加把手。
            path.lineWidth = isSelected ? 1.5 : 1
            if !isSelected { path.setLineDash([4, 4], count: 2, phase: 0) }
            color.withAlphaComponent(isSelected ? 1 : 0.55).setStroke()
            path.stroke()
            guard isSelected else { continue }
            color.withAlphaComponent(0.10).setFill(); path.fill()
            for handle in MaskCanvasMath.Handle.allCases where handle != .body {
                let anchor = handle.anchor
                let center = CGPoint(x: item.rect.minX + item.rect.width * anchor.x, y: item.rect.maxY - item.rect.height * anchor.y)
                let box = CGRect(x: center.x - Self.handleSize / 2, y: center.y - Self.handleSize / 2, width: Self.handleSize, height: Self.handleSize)
                let dot = NSBezierPath(ovalIn: box)
                color.setFill(); dot.fill()
                NSColor.white.withAlphaComponent(0.9).setStroke(); dot.lineWidth = 1.5; dot.stroke()
            }
        }
    }
}

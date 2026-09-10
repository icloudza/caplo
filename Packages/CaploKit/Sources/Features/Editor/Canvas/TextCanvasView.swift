import AppKit
import CaploDesignSystem
import EditingCore
import RenderKit

/// 画布上的文字编辑层：画出当前时刻的文字框，拖框体挪位置、拖四角等比改字号。
///
/// 折行宽度（`maxWidth`）不放在画布上：它一改就可能多一行少一行，横着拖会把高度也带着变
/// （实测两行拉成一行，框高 100 点当场掉到 50 点、整块还往上跳）。那一项在「排版 → 最大宽度」的卡尺里调。
///
/// 文字定位在输出画面坐标里，所以这里不需要遮罩那套内容坐标的反变换——
/// 文字盒就是渲染器排版用的那一个，两边共用 `TextRenderer`，画出来的框必然和成片一致。
///
/// 拖动的手感与「自定义布局」是同一套：同样的吸附距离与参考线（`CustomLayoutMath.snap`），
/// 同样的近白色虚线框与把手、粉色参考线，中线吸上就是一个十字。
@MainActor
final class TextCanvasView: NSView {
    private let model: VideoEditorModel
    private weak var canvas: CanvasSurfaceView?
    private typealias Handle = TextCanvasMath.Handle
    private struct Drag {
        let id: UUID
        let handle: Handle
        let origin: CGPoint
        let anchor: CGPoint
        let size: Double
        /// 按下时把手对角（或对边）的位置，等比改字号时以它为不动点。
        let pivot: CGPoint
        let reach: Double
        /// 按下时文字框在本视图里的位置；吸附按整块框算，再把位移换回锚点。
        let rect: CGRect
        /// 按下时文字字形的大小，改字号时拿它折算比例。
        let glyph: CGSize
        var moved = false
    }
    private var drag: Drag?
    /// 拖动中吸上的参考线，与自定义布局同样画成贯穿画布的粉线。
    private var guides: [CustomLayoutMath.Guide] = []
    private var hovered: Handle?
    private static let cornerSize: CGFloat = 12
    private static let hitSlop: CGFloat = 5

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

    private var active: Bool { model.textEditing && !model.playing && !model.edit.textList.isEmpty }
    private var time: Double { model.skimPosition ?? model.position }

    /// 当前时刻要画的文字框，从下到上。矩形已经换算到本视图坐标。
    private func visible() -> [(id: UUID, rect: CGRect)] {
        guard let videoRect = canvas?.videoRect, videoRect.width > 1 else { return [] }
        let local = convert(videoRect, from: canvas)
        let light = SceneRenderer.isLightBackground(model.edit.layout)
        let states = model.edit.activeTexts(at: time)
        return states.compactMap { state in
            // 框住看得见的那一块：带底板的预设（代码、字幕条）底板比文字大一圈，
            // 只框文字的话框会落在底板里面，把手压在底板脸上，看着就是错位。
            guard let frame = TextRenderer.shared.visibleFrame(for: state, canvas: local.size, lightBackground: light) else { return nil }
            return (state.id, frame.offsetBy(dx: local.minX, dy: local.minY))
        }
    }

    /// 留白框：画面布局的留白，与自定义布局里那条参照一致。
    private func innerRect(_ canvas: CGRect) -> CGRect {
        let padding = model.edit.layout.padding * canvas.width / 960
        guard canvas.width > 2 * padding, canvas.height > 2 * padding else { return canvas }
        return canvas.insetBy(dx: padding, dy: padding)
    }

    /// 另一块可吸附的东西：当前时刻画面层所在的矩形（全屏卡段淡出、分屏退到一栏都算进去）。
    private func snapTargets(_ canvas: CGRect) -> [CGRect] {
        let full = model.entry.document.capture?.pixelSize ?? CGSize(width: 1920, height: 1080)
        let source = SceneRenderer.croppedSourceSize(full.width > 0 && full.height > 0 ? full : CGSize(width: 1920, height: 1080),
                                                     layout: model.edit.layout)
        let stage = model.edit.stage(at: time)
        guard stage.alpha > 0.05 else { return [] }
        let picture = SceneRenderer.geometry(edit: SceneRenderer.stagedEdit(model.edit, stage: stage), sourceSize: source, size: canvas.size).rect
            .applying(stage.affine(canvas: canvas.size))
        guard picture.width > 1, picture.height > 1 else { return [] }
        return [picture.offsetBy(dx: canvas.minX, dy: canvas.minY)]
    }

    /// 测试用：某段文字此刻在本视图里的包围盒。
    func textFrameForTesting(_ id: UUID) -> CGRect? { visible().first { $0.id == id }?.rect }

    private func target(at point: CGPoint) -> (id: UUID, handle: Handle, rect: CGRect)? {
        let items = visible()
        if let selected = model.selectedText, let item = items.first(where: { $0.id == selected }),
           let handle = TextCanvasMath.handle(at: point, textFrame: item.rect,
                                              cornerSize: Self.cornerSize, slop: Self.hitSlop) {
            return (item.id, handle, item.rect)
        }
        for item in items.reversed() where item.id != model.selectedText {
            if TextCanvasMath.handleFrame(item.rect).insetBy(dx: -4, dy: -4).contains(point) { return (item.id, .body, item.rect) }
        }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard active else { return nil }
        return target(at: convert(point, from: superview)) == nil ? nil : self
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard active, let hit = target(at: point) else { return }
        if model.selectedText != hit.id {
            model.selectedText = hit.id; model.selectedFocus = nil; model.selectedMask = nil
            model.selectedMedia = nil; model.selectedMediaID = nil
            needsDisplay = true
            if hit.handle == .body { return }
        }
        guard let value = model.edit.text(id: hit.id) else { return }
        // 等比改字号以对角为不动点；改最大宽度以文字块中线为参照。
        let pivot = TextCanvasMath.pivot(for: hit.handle, textFrame: hit.rect)
        drag = Drag(id: hit.id, handle: hit.handle, origin: point,
                    anchor: CGPoint(x: value.x, y: value.y), size: value.size,
                    pivot: pivot, reach: max(1, hypot(point.x - pivot.x, point.y - pivot.y)),
                    rect: hit.rect, glyph: hit.rect.size)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var current = drag, let videoRect = canvas?.videoRect else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !current.moved, hypot(point.x - current.origin.x, point.y - current.origin.y) < 2 { return }
        current.moved = true; drag = current
        let local = convert(videoRect, from: canvas)
        guard let value = model.edit.text(id: current.id) else { return }
        let box = TextRenderer.box(for: value, canvas: local.size)
        guard box.width > 1, box.height > 1 else { return }
        model.beginInteraction()
        var edit = model.edit
        switch current.handle {
        case .body:
            let dragged = TextCanvasMath.drag(anchor: current.anchor, rect: current.rect,
                                              translation: CGSize(width: point.x - current.origin.x, height: point.y - current.origin.y),
                                              box: box.size, canvas: local, inner: innerRect(local), targets: snapTargets(local))
            guides = dragged.guides
            edit.updateText(id: current.id) { $0.x = dragged.anchor.x; $0.y = dragged.anchor.y }
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let next = TextCanvasMath.size(current.size,
                                           distance: hypot(point.x - current.pivot.x, point.y - current.pivot.y),
                                           startDistance: current.reach, glyph: current.glyph, range: TextSegment.sizeRange)
            edit.updateText(id: current.id) { $0.size = next }
        }
        if model.edit != edit { model.edit = edit; model.previewChanged() }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; guides = []; needsDisplay = true }
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
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        // 拖动中认按下时抓的那个把手：手已经离开把手了，光标也不该变回箭头。
        if let drag {
            (drag.handle == .body ? NSCursor.closedHand : Self.cursor(for: drag.handle)).set()
            return
        }
        guard let hovered else { super.cursorUpdate(with: event); return }
        Self.cursor(for: hovered).set()
    }

    private static func cursor(for handle: Handle) -> NSCursor {
        switch handle {
        case .body: .openHand
        default: .crosshair
        }
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53, drag != nil else { super.keyDown(with: event); return }
        model.cancelInteraction(); drag = nil; guides = []; needsDisplay = true
    }

    // MARK: 刷新与绘制

    private struct State: Equatable {
        let edit: VideoEdit
        let time: Double
        let selection: UUID?
        let editing: Bool
        let playing: Bool
        var isActive: Bool { editing && !playing && !edit.textList.isEmpty }
    }
    private var applied: State?

    func refreshFor(edit: VideoEdit, time: Double, selection: UUID?, editing: Bool, playing: Bool) {
        let state = State(edit: edit, time: time, selection: selection, editing: editing, playing: playing)
        guard state != applied else { return }
        let wasActive = applied?.isActive ?? false
        applied = state
        needsDisplay = true
        if wasActive != state.isActive { updateTrackingAreas(); if !state.isActive { hovered = nil } }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard active else { return }
        let selected = model.selectedText
        for item in visible() {
            let isSelected = item.id == selected
            let rect = TextCanvasMath.handleFrame(item.rect)
            let path = NSBezierPath(rect: rect)
            path.lineWidth = isSelected ? 1.5 : 1
            // 与自定义布局同一套：近白色的虚线框，选中的那一条粗一点、不透明。
            path.setLineDash([5, 4], count: 2, phase: 0)
            CaploNSColor.accent.withAlphaComponent(isSelected ? 1 : 0.5).setStroke()
            path.stroke()
            guard isSelected else { continue }
            // 四角是实心圆（等比改字号），与自定义布局里的把手同一套语言。
            for point in [CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
                          CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)] {
                let box = CGRect(x: point.x - Self.cornerSize / 2, y: point.y - Self.cornerSize / 2,
                                 width: Self.cornerSize, height: Self.cornerSize)
                let dot = NSBezierPath(ovalIn: box)
                CaploNSColor.accent.setFill(); dot.fill()
                NSColor.white.withAlphaComponent(0.9).setStroke(); dot.lineWidth = 1.5; dot.stroke()
            }
        }
        drawGuides()
    }

    /// 吸附参考线：竖线贯穿画布整高、横线贯穿整宽，中线吸上就是一个十字。与自定义布局同色同粗细。
    private func drawGuides() {
        guard !guides.isEmpty, let videoRect = canvas?.videoRect else { return }
        let local = convert(videoRect, from: canvas)
        let path = NSBezierPath()
        for guide in guides {
            switch guide {
            case .vertical(let x):
                path.move(to: CGPoint(x: x, y: local.minY)); path.line(to: CGPoint(x: x, y: local.maxY))
            case .horizontal(let y):
                path.move(to: CGPoint(x: local.minX, y: y)); path.line(to: CGPoint(x: local.maxX, y: y))
            }
        }
        path.lineWidth = 1
        CaploNSColor.record.setStroke()
        path.stroke()
    }
}

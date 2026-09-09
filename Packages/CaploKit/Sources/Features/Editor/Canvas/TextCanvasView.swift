import AppKit
import CaploDesignSystem
import EditingCore
import RenderKit

/// 画布上的文字编辑层：画出当前时刻的文字框，拖框体挪位置、拖四角改字号、拖左右中点改最大宽度。
///
/// 文字定位在输出画面坐标里，所以这里不需要遮罩那套内容坐标的反变换——
/// 文字盒就是渲染器排版用的那一个，两边共用 `TextRenderer`，画出来的框必然和成片一致。
@MainActor
final class TextCanvasView: NSView {
    private let model: VideoEditorModel
    private weak var canvas: CanvasSurfaceView?
    private enum Handle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight, left, right, body
        var isCorner: Bool { self == .topLeft || self == .topRight || self == .bottomLeft || self == .bottomRight }
        var isSide: Bool { self == .left || self == .right }
    }
    private struct Drag {
        let id: UUID
        let handle: Handle
        let origin: CGPoint
        let anchor: CGPoint
        let size: Double
        let maxWidth: Double
        /// 按下时把手对角（或对边）的位置，等比改字号时以它为不动点。
        let pivot: CGPoint
        let reach: Double
        var moved = false
    }
    private var drag: Drag?
    private var hovered: Handle?
    private static let cornerSize: CGFloat = 12
    private static let sideSize: CGFloat = 8
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
            guard let frame = TextRenderer.shared.textFrame(for: state, canvas: local.size, lightBackground: light) else { return nil }
            return (state.id, frame.offsetBy(dx: local.minX, dy: local.minY))
        }
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        // 与遮罩同一条：文字盒被分屏压窄时，把手的命中区不收窄的话就连成一片、盒体拖不动。
        let corner = MaskCanvasMath.handleReach(rect, size: Self.cornerSize, slop: Self.hitSlop)
        let side = MaskCanvasMath.handleReach(rect, size: Self.sideSize, slop: Self.hitSlop)
        let anchors: [(Handle, CGPoint, CGFloat)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.maxY), corner),
            (.topRight, CGPoint(x: rect.maxX, y: rect.maxY), corner),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY), corner),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY), corner),
            (.left, CGPoint(x: rect.minX, y: rect.midY), side),
            (.right, CGPoint(x: rect.maxX, y: rect.midY), side),
        ]
        for (handle, center, reach) in anchors where abs(point.x - center.x) <= reach && abs(point.y - center.y) <= reach {
            return handle
        }
        return rect.insetBy(dx: -4, dy: -4).contains(point) ? .body : nil
    }

    private func target(at point: CGPoint) -> (id: UUID, handle: Handle, rect: CGRect)? {
        let items = visible()
        if let selected = model.selectedText, let item = items.first(where: { $0.id == selected }),
           let handle = handle(at: point, in: item.rect) { return (item.id, handle, item.rect) }
        for item in items.reversed() where item.id != model.selectedText {
            if item.rect.insetBy(dx: -4, dy: -4).contains(point) { return (item.id, .body, item.rect) }
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
        let pivot: CGPoint = switch hit.handle {
        case .topLeft: CGPoint(x: hit.rect.maxX, y: hit.rect.minY)
        case .topRight: CGPoint(x: hit.rect.minX, y: hit.rect.minY)
        case .bottomLeft: CGPoint(x: hit.rect.maxX, y: hit.rect.maxY)
        case .bottomRight: CGPoint(x: hit.rect.minX, y: hit.rect.maxY)
        default: CGPoint(x: hit.rect.midX, y: hit.rect.midY)
        }
        drag = Drag(id: hit.id, handle: hit.handle, origin: point,
                    anchor: CGPoint(x: value.x, y: value.y), size: value.size, maxWidth: value.maxWidth,
                    pivot: pivot, reach: max(1, hypot(point.x - pivot.x, point.y - pivot.y)))
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
            // 锚点的 y 是从上往下量的，视图是 y 向上，所以纵向要取反。
            let dx = (point.x - current.origin.x) / box.width
            let dy = -(point.y - current.origin.y) / box.height
            edit.updateText(id: current.id) {
                $0.x = min(1.2, max(-0.2, current.anchor.x + dx))
                $0.y = min(1.2, max(-0.2, current.anchor.y + dy))
            }
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let distance = hypot(point.x - current.pivot.x, point.y - current.pivot.y)
            let next = current.size * distance / current.reach
            edit.updateText(id: current.id) {
                $0.size = min(TextSegment.sizeRange.upperBound, max(TextSegment.sizeRange.lowerBound, next))
            }
        case .left, .right:
            let half = abs(point.x - current.pivot.x)
            edit.updateText(id: current.id) { $0.maxWidth = min(1, max(0.2, half * 2 / box.width)) }
        }
        if model.edit != edit { model.edit = edit; model.previewChanged() }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; needsDisplay = true }
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
        case .left, .right: NSCursor.resizeLeftRight.set()
        case .some: NSCursor.crosshair.set()
        case nil: super.cursorUpdate(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53, drag != nil else { super.keyDown(with: event); return }
        model.cancelInteraction(); drag = nil; needsDisplay = true
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
            let rect = item.rect.insetBy(dx: -6, dy: -6)
            let path = NSBezierPath(rect: rect)
            path.lineWidth = isSelected ? 1.5 : 1
            if !isSelected { path.setLineDash([5, 4], count: 2, phase: 0) }
            CaploNSColor.textLayer.withAlphaComponent(isSelected ? 1 : 0.5).setStroke()
            path.stroke()
            guard isSelected else { continue }
            // 四角是实心圆（等比改字号），左右中点是圆角方块（改最大宽度），与自定义布局里的把手同一套语言。
            for point in [CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
                          CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)] {
                let box = CGRect(x: point.x - Self.cornerSize / 2, y: point.y - Self.cornerSize / 2,
                                 width: Self.cornerSize, height: Self.cornerSize)
                let dot = NSBezierPath(ovalIn: box)
                CaploNSColor.accent.setFill(); dot.fill()
                NSColor.white.withAlphaComponent(0.9).setStroke(); dot.lineWidth = 1.5; dot.stroke()
            }
            for point in [CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY)] {
                let box = CGRect(x: point.x - Self.sideSize / 2, y: point.y - Self.sideSize / 2,
                                 width: Self.sideSize, height: Self.sideSize)
                let square = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
                CaploNSColor.accent.setFill(); square.fill()
                NSColor.white.withAlphaComponent(0.9).setStroke(); square.lineWidth = 1.2; square.stroke()
            }
        }
    }
}

import AppKit
import QuartzCore
import CaploDesignSystem

/// 总览仅接收块的时间和类别，不读取视频帧或音频样本。
struct TimelineNavigatorItem: Equatable, Sendable {
    enum Kind: Int, CaseIterable, Sendable { case screen, camera, focus, audio }
    let id: UUID
    let start: Double
    let duration: Double
    let kind: Kind
}

/// 独立图层承载总览，分界改变高度时同步移动到新底边，不复用父视口冻结的位图。
@MainActor
final class TimelineNavigatorView: NSView {
    /// 视口底部预留与组件固有高度共用，避免增高后覆盖最后一条轨道。
    static let preferredHeight: CGFloat = 40
    var onRangeChange: ((Double, Double) -> Void)?
    private var items: [TimelineNavigatorItem] = []
    private var totalDuration = 0.0
    private var visibleStart = 0.0
    private var visibleDuration = 0.0
    private var playheadTime = 0.0
    private var drag: Drag?
    private var materialObserver: NSObjectProtocol?
    var materialOpaqueOverride: Bool? { didSet { if oldValue != materialOpaqueOverride { updateAppearance() } } }
    private let rail = CAShapeLayer()
    private let sheen = CAGradientLayer()
    private let itemLayers = TimelineNavigatorItem.Kind.allCases.map { _ in CAShapeLayer() }
    private let outsideShade = CAShapeLayer()
    private let rangeLayer = CAShapeLayer()
    private let handles = CAShapeLayer()
    private let playheadLayer = CALayer()
    private var needsOverviewPath = true
    private var lastOverviewSize = CGSize.zero
    private var lastOverviewDuration = -1.0
    private(set) var visibleRangeRect = CGRect.zero
    private(set) var overviewBuildCount = 0
    private var overviewRect: CGRect { bounds.insetBy(dx: 4, dy: 4) }
    private var mappingDuration: Double { drag?.total ?? totalDuration }
    var isInteracting: Bool { drag != nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight) }

    private struct Drag {
        enum Kind { case body, leading, trailing }
        let kind: Kind
        let origin: Double
        let start: Double
        let length: Double
        let originalStart: Double
        let originalLength: Double
        // 总时长和像素比例在按下时冻结，拖动期间外部扩展时间轴不会改变增量映射。
        let total: Double
        let width: Double
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // 总览整面只用一个渐变图层；播放推进仍只移动播放头，不重建材质。
        sheen.cornerRadius = 4; sheen.masksToBounds = true
        sheen.startPoint = CGPoint(x: 0, y: 0); sheen.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(sheen)
        for child in [rail] + itemLayers + [outsideShade, rangeLayer, handles] { layer?.addSublayer(child) }
        layer?.addSublayer(playheadLayer)
        rangeLayer.lineWidth = 1.2
        handles.lineWidth = 1.5
        handles.lineCap = .round
        playheadLayer.cornerRadius = 0.5
        toolTip = "拖动浏览 · 拖两端缩放 · 双击全览"
        setAccessibilityElement(true)
        setAccessibilityRole(.scrollBar)
        setAccessibilityOrientation(.horizontal)
        setAccessibilityLabel("时间线总览")
        setAccessibilityHelp("左右方向键移动视窗，加减键缩放，双击显示全部")
        updateAppearance()
        updateLayers()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(items: [TimelineNavigatorItem], duration: Double, visibleStart: Double, visibleDuration: Double, playhead: Double) {
        if self.items != items { self.items = items; needsOverviewPath = true }
        totalDuration = duration.isFinite ? max(0, duration) : 0
        let range = clampedRange(start: visibleStart, length: visibleDuration, total: mappingDuration)
        self.visibleStart = range.start; self.visibleDuration = range.length
        playheadTime = playhead.isFinite ? max(0, playhead) : 0
        updateLayers()
    }

    /// 播放刷新可只移动这条图层，避免每帧重新比较全部总览项。
    func updatePlayhead(_ time: Double) {
        playheadTime = time.isFinite ? max(0, time) : 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        updatePlayheadLayer()
        CATransaction.commit()
    }

    /// 平移和播放跟随只改变视窗；总时长与尺寸未变时复用类别路径。
    func updateVisibleRange(start: Double, duration: Double, totalDuration: Double) {
        self.totalDuration = totalDuration.isFinite ? max(0, totalDuration) : 0
        // 父视口可能夹紧最大缩放，接收其真实范围反馈；只冻结时间比例，不冻结视窗结果。
        let range = clampedRange(start: start, length: duration, total: mappingDuration)
        visibleStart = range.start; visibleDuration = range.length
        updateLayers()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // 与父视口冻结策略解耦：尺寸变化这一刻即重算几何，不等待下一次 display / layout。
        updateLayers()
    }
    override func layout() { super.layout(); updateLayers() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateAppearance() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        EditorMaterialDrawing.stopObserving(&materialObserver)
        if window != nil {
            materialObserver = EditorMaterialDrawing.observeChanges { [weak self] in self?.updateAppearance() }
        }
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let opaque = EditorMaterialDrawing.usesOpaqueSurface(appearance: effectiveAppearance, opaqueOverride: materialOpaqueOverride)
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.isOpaque = false
            sheen.backgroundColor = EditorMaterialDrawing.color(EditorMaterialDrawing.surface(CaploNSColor.surfaceCanvasWell, opaque: CaploNSColor.surfaceOpaqueRaised, appearance: effectiveAppearance, opaqueOverride: materialOpaqueOverride), appearance: effectiveAppearance)
            sheen.colors = opaque ? nil : EditorMaterialDrawing.gradientColors(appearance: effectiveAppearance)
            rail.fillColor = nil
            rail.strokeColor = CaploNSColor.glassEdge.cgColor
            rail.lineWidth = CaploMetrics.hairline
            let colors = [CaploNSColor.accent, CaploNSColor.warning, CaploNSColor.zoom, CaploNSColor.audio]
            for (item, color) in zip(itemLayers, colors) { item.fillColor = color.withAlphaComponent(0.28).cgColor }
            outsideShade.fillColor = CaploNSColor.glassShade.cgColor
            rangeLayer.fillColor = CaploNSColor.accent.withAlphaComponent(0.06).cgColor
            rangeLayer.strokeColor = CaploNSColor.accent.withAlphaComponent(0.78).cgColor
            handles.fillColor = nil
            handles.strokeColor = CaploNSColor.accent.withAlphaComponent(0.88).cgColor
            playheadLayer.backgroundColor = CaploNSColor.record.cgColor
            let scale = window?.backingScaleFactor ?? 2
            for child in layer?.sublayers ?? [] { child.contentsScale = scale }
            CATransaction.commit()
        }
    }

    private func updateLayers() {
        let area = overviewRect
        guard area.width > 0, area.height > 0 else { layer?.sublayers?.forEach { $0.isHidden = true }; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        sheen.frame = area; sheen.isHidden = false
        rail.isHidden = false
        rail.path = CGPath(roundedRect: area, cornerWidth: 4, cornerHeight: 4, transform: nil)
        let total = mappingDuration
        let valid = total > 0 && total.isFinite
        outsideShade.isHidden = !valid; rangeLayer.isHidden = !valid; handles.isHidden = !valid
        if needsOverviewPath || lastOverviewSize != bounds.size || lastOverviewDuration != total {
            let paths = TimelineNavigatorItem.Kind.allCases.map { _ in CGMutablePath() }
            let gap = 2.0, height = max(1, min(4, (area.height - 6 - 3 * gap) / 4))
            let top = area.midY - (height * 4 + gap * 3) / 2
            if valid {
                // 按可见像素汇总占用区间，十万块也只形成与总览宽度有关的有限路径。
                // 差分累加避免每个长片段重复遍历其覆盖的全部像素。
                let columns = max(1, min(8192, Int(ceil(area.width))))
                var coverage = TimelineNavigatorItem.Kind.allCases.map { _ in [Int](repeating: 0, count: columns + 1) }
                for item in items where item.start.isFinite && item.duration.isFinite && item.duration > 0 {
                    let start = max(0, item.start), end = min(total, item.start + item.duration)
                    guard start < end else { continue }
                    let first = min(columns - 1, Int(floor(start / total * Double(columns))))
                    let last = min(columns, max(first + 1, Int(ceil(end / total * Double(columns)))))
                    coverage[item.kind.rawValue][first] += 1; coverage[item.kind.rawValue][last] -= 1
                }
                for kind in TimelineNavigatorItem.Kind.allCases {
                    var depth = 0, beginning: Int?
                    for column in 0...columns {
                        depth += coverage[kind.rawValue][column]
                        if depth > 0, beginning == nil { beginning = column }
                        if depth == 0, let first = beginning {
                            let x = area.minX + Double(first) / Double(columns) * area.width
                            let width = Double(column - first) / Double(columns) * area.width
                            paths[kind.rawValue].addRoundedRect(in: CGRect(x: x, y: top + Double(kind.rawValue) * (height + gap), width: width, height: height), cornerWidth: 1, cornerHeight: 1)
                            beginning = nil
                        }
                    }
                }
            }
            for (item, path) in zip(itemLayers, paths) { item.path = path; item.isHidden = !valid }
            lastOverviewSize = bounds.size; lastOverviewDuration = total; needsOverviewPath = false
            overviewBuildCount += 1
        }
        guard valid else { visibleRangeRect = .zero; playheadLayer.isHidden = true; return }
        visibleRangeRect = rangeRect(start: visibleStart, length: visibleDuration, total: total, area: area)
        rangeLayer.path = CGPath(roundedRect: visibleRangeRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        let shade = CGMutablePath()
        shade.addRect(CGRect(x: area.minX, y: area.minY, width: max(0, visibleRangeRect.minX - area.minX), height: area.height))
        shade.addRect(CGRect(x: visibleRangeRect.maxX, y: area.minY, width: max(0, area.maxX - visibleRangeRect.maxX), height: area.height))
        outsideShade.path = shade
        let grips = CGMutablePath()
        let gripHalfHeight = min(8, max(4, area.height / 4))
        for x in [visibleRangeRect.minX + 4, visibleRangeRect.maxX - 4] {
            grips.move(to: CGPoint(x: x, y: area.midY - gripHalfHeight)); grips.addLine(to: CGPoint(x: x, y: area.midY + gripHalfHeight))
        }
        handles.path = grips
        updatePlayheadLayer()
        setAccessibilityValue(String(format: "%.2f 至 %.2f 秒，共 %.2f 秒", visibleStart, visibleStart + visibleDuration, totalDuration))
        window?.invalidateCursorRects(for: self)
    }

    private func updatePlayheadLayer() {
        let total = mappingDuration, area = overviewRect
        guard total > 0, area.width > 0, area.height > 0, playheadTime <= total else { playheadLayer.isHidden = true; return }
        let x = min(area.maxX - 1, area.minX + playheadTime / total * area.width)
        playheadLayer.frame = CGRect(x: x, y: area.minY + 1, width: 1.2, height: area.height - 2)
        playheadLayer.isHidden = false
    }

    private func clampedRange(start: Double, length: Double, total: Double) -> (start: Double, length: Double) {
        guard total > 0 else { return (0, 0) }
        let length = min(total, max(minimumLength(total), length.isFinite ? length : total))
        return (min(total - length, max(0, start.isFinite ? start : 0)), length)
    }
    private func minimumLength(_ total: Double) -> Double { min(total, max(0.000_001, total * 0.000_001)) }
    private func rangeRect(start: Double, length: Double, total: Double, area: CGRect) -> CGRect {
        let width = min(area.width, max(24, length / total * area.width))
        // 极短视窗只扩展命中尺寸；实际时间范围不随 24pt 最小视觉宽度改变。
        let center = area.minX + (start + length / 2) / total * area.width
        let x = min(area.maxX - width, max(area.minX, center - width / 2))
        return CGRect(x: x, y: area.minY, width: width, height: area.height)
    }

    override func mouseDown(with event: NSEvent) {
        guard mappingDuration > 0, overviewRect.width > 0 else { return }
        window?.makeFirstResponder(self)
        let x = convert(event.locationInWindow, from: nil).x
        if event.clickCount == 2 { publish(start: 0, length: totalDuration); return }
        let originalStart = visibleStart, originalLength = visibleDuration
        let kind: Drag.Kind
        let start: Double
        if x >= visibleRangeRect.minX && x <= visibleRangeRect.maxX {
            if x - visibleRangeRect.minX < 7 { kind = .leading }
            else if visibleRangeRect.maxX - x < 7 { kind = .trailing }
            else { kind = .body }
            start = originalStart
        } else {
            kind = .body
            let clickedTime = (x - overviewRect.minX) / overviewRect.width * totalDuration
            start = clampedRange(start: clickedTime - originalLength / 2, length: originalLength, total: totalDuration).start
        }
        drag = Drag(kind: kind, origin: x, start: start, length: originalLength, originalStart: originalStart, originalLength: originalLength, total: totalDuration, width: overviewRect.width)
        if start != originalStart { publish(start: start, length: originalLength) }
        if kind == .body { NSCursor.closedHand.set() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let delta = (x - drag.origin) / drag.width * drag.total
        switch drag.kind {
        case .body: publish(start: drag.start + delta, length: drag.length)
        case .leading:
            let end = drag.start + drag.length
            let start = min(end - minimumLength(drag.total), max(0, drag.start + delta))
            publish(start: start, length: end - start)
        case .trailing:
            let end = min(drag.total, max(drag.start + minimumLength(drag.total), drag.start + drag.length + delta))
            publish(start: drag.start, length: end - drag.start)
        }
    }
    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        mouseDragged(with: event)
        drag = nil
        updateLayers()
    }

    private func publish(start: Double, length: Double) {
        let range = clampedRange(start: start, length: length, total: mappingDuration)
        let changed = visibleStart != range.start || visibleDuration != range.length
        visibleStart = range.start; visibleDuration = range.length
        updateLayers()
        if changed { onRangeChange?(range.start, range.length) }
    }
    func cancelInteraction() {
        guard let original = drag else { return }
        drag = nil
        publish(start: original.originalStart, length: original.originalLength)
    }
    func detach() { EditorMaterialDrawing.stopObserving(&materialObserver); drag = nil; onRangeChange = nil }

    override func resetCursorRects() {
        guard !visibleRangeRect.isEmpty else { return }
        addCursorRect(visibleRangeRect, cursor: .openHand)
        addCursorRect(CGRect(x: visibleRangeRect.minX, y: visibleRangeRect.minY, width: 7, height: visibleRangeRect.height), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: visibleRangeRect.maxX - 7, y: visibleRangeRect.minY, width: 7, height: visibleRangeRect.height), cursor: .resizeLeftRight)
    }
    override func scrollWheel(with event: NSEvent) {
        guard drag == nil else { return }
        let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        publish(start: visibleStart - Double(delta) * visibleDuration / max(1, overviewRect.width), length: visibleDuration)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelInteraction(); return }
        guard drag == nil else { return }
        let step = visibleDuration * (event.modifierFlags.contains(.shift) ? 0.5 : 0.1)
        switch event.keyCode {
        case 123: publish(start: visibleStart - step, length: visibleDuration)
        case 124: publish(start: visibleStart + step, length: visibleDuration)
        case 115: publish(start: 0, length: visibleDuration)
        case 119: publish(start: totalDuration - visibleDuration, length: visibleDuration)
        default:
            switch event.charactersIgnoringModifiers {
            case "+", "=": publish(start: visibleStart + visibleDuration * 0.1, length: visibleDuration * 0.8)
            case "-": publish(start: visibleStart - visibleDuration * 0.125, length: visibleDuration * 1.25)
            default: super.keyDown(with: event)
            }
        }
    }
}

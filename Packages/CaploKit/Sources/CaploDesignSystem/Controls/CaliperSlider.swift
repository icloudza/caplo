import AppKit
import SwiftUI
import QuartzCore

// MARK: - 配置

/// 卡尺滑块的全部可配参数。五种形态都是这些参数的组合：
/// 刻度滚动 = `.scroll`；游标滑动 = `.fixed`；拨轮磁吸 = `.scroll` + `fade` + `magnet: .detents`；
/// 面板紧凑 = `size: .compact`；范围 = `CaliperRangeSlider`（轨道强制 `.fixed`）。
public struct CaliperConfiguration: Equatable, Sendable {
    public enum Track: Sendable { case scroll, fixed }
    public enum Size: Sendable { case regular, compact }
    public enum Magnet: Sendable { case none, major, detents }
    public enum SnapTo: Sendable { case step, detents }
    public enum Fade: Sendable { case auto, on, off }
    public enum ShowValue: Sendable { case bubble, none }

    public var track: Track = .scroll
    public var size: Size = .compact
    public var range: ClosedRange<Double> = 0...100
    /// 量化步长（值只会停在 step 的整数倍上）。
    public var step: Double = 1
    /// 画刻度的间隔；nil 时用 step，并在像素太密时自动放粗。
    public var tickStep: Double?
    public var major: Double = 10
    public var mid: Double?
    /// 滚动轨道每单位值的像素数；固定轨道按宽度自适应。
    public var pxPerUnit: Double = 6
    public var detents: [Double] = []
    public var magnet: Magnet = .none
    public var snapTo: SnapTo = .step
    public var inertia = true
    public var fade: Fade = .auto
    public var decimals = 0
    public var suffix = ""
    public var defaultValue: Double?
    public var showValue: ShowValue = .bubble
    /// 阻尼（0…1）：显示值按时间常数 0.12 秒 × damping 指数跟随指针，越大越"沉"；0 为即时跟手。
    /// 滚动轨道越过端点时还会带阻力拉出、松手回弹；系统"减少动态效果"开启时一律即时。
    public var damping: Double = 0.3
    /// 每跨过一个刻度步发一声"咔嗒"；nil 表示只有滚动轨道响。
    public var sound: Bool?

    public init(track: Track = .scroll, size: Size = .compact, range: ClosedRange<Double> = 0...100, step: Double = 1, tickStep: Double? = nil,
                major: Double = 10, mid: Double? = nil, pxPerUnit: Double = 6, detents: [Double] = [], magnet: Magnet = .none, snapTo: SnapTo = .step,
                inertia: Bool = true, fade: Fade = .auto, decimals: Int = 0, suffix: String = "", defaultValue: Double? = nil, showValue: ShowValue = .bubble,
                damping: Double = 0.3, sound: Bool? = nil) {
        self.track = track; self.size = size; self.range = range; self.step = step; self.tickStep = tickStep; self.major = major; self.mid = mid
        self.pxPerUnit = pxPerUnit; self.detents = detents; self.magnet = magnet; self.snapTo = snapTo; self.inertia = inertia; self.fade = fade
        self.decimals = decimals; self.suffix = suffix; self.defaultValue = defaultValue; self.showValue = showValue
        self.damping = damping; self.sound = sound
    }

    /// 由范围推一组"好看"的刻度：主刻度取 1 / 2 / 2.5 / 5 × 10ⁿ 里让全程约 6–8 格的那个。
    public static func auto(range: ClosedRange<Double>, step: Double? = nil, decimals: Int? = nil, track: Track = .scroll) -> CaliperConfiguration {
        let span = max(range.upperBound - range.lowerBound, 0.000_001)
        let major = nice(span / 7)
        let resolvedStep = step ?? nice(span / 120)
        let resolvedDecimals = decimals ?? max(0, Int((-log10(resolvedStep)).rounded(.up)))
        var config = CaliperConfiguration(track: track, range: range, step: resolvedStep, major: major, mid: major / 2, decimals: resolvedDecimals)
        config.tickStep = nice(major / 10)
        config.pxPerUnit = track == .scroll ? 160 / span : 1
        return config
    }

    /// 最接近的 1 / 2 / 2.5 / 5 × 10ⁿ。
    public static func nice(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let exponent = floor(log10(value)), base = value / pow(10, exponent)
        let candidate: Double = base < 1.5 ? 1 : base < 2.25 ? 2 : base < 3.5 ? 2.5 : base < 7.5 ? 5 : 10
        return candidate * pow(10, exponent)
    }

    var effectiveMid: Double { mid ?? major / 2 }
    var fades: Bool { fade == .on || (fade == .auto && track == .scroll) }
    public var height: CGFloat { size == .compact ? 26 : 64 }
}

// MARK: - AppKit 实现

/// 卡尺滑块本体：两层图形——刻度（含标签、档位）是一整块，拖动只平移它；游标与气泡是另一层。
/// 没有逐帧重绘，拖动、惯性、吸附都只改图层位置。支持单值与区间（`handles = 2`）。
@MainActor
public final class CaliperView: NSView {
    public var configuration: CaliperConfiguration { didSet { if configuration != oldValue { rebuild() } } }
    public private(set) var value: Double
    public private(set) var lowerValue: Double
    public private(set) var upperValue: Double
    public let handles: Int
    public var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.4; window?.invalidateCursorRects(for: self) } }
    /// 每一步（拖动、滚轮、键盘、动画）都会调用；`onCommit` 只在松手 / 吸附完成 / 滚轮停顿后调用一次。
    public var onChange: ((Double) -> Void)?
    public var onRangeChange: ((Double, Double) -> Void)?
    public var onEditingChanged: ((Bool) -> Void)?
    public var onReset: (() -> Void)?
    public private(set) var isInteracting = false
    public var reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private let trackLayer = CALayer()
    private let content = CALayer()
    private let minorLayer = CAShapeLayer(), midLayer = CAShapeLayer(), majorLayer = CAShapeLayer(), detentLayer = CAShapeLayer()
    private let rangeLayer = CALayer()
    private let pointerLayer = CAShapeLayer(), upperPointerLayer = CAShapeLayer()
    private let bubbleLayer = CALayer(), bubbleText = CATextLayer(), upperBubbleLayer = CALayer(), upperBubbleText = CATextLayer()
    private let focusLayer = CALayer()
    private var labels: [CATextLayer] = []
    private var fadeMask: CAGradientLayer?
    private var builtWidth: CGFloat = -1
    private var hovered = false
    private var dragging = false
    private var grab: Grab = .single
    private var grabStart: (x: CGFloat, lo: Double, hi: Double) = (0, 0, 0)
    private var lastX: CGFloat = 0, lastTime: TimeInterval = 0, velocity: Double = 0
    private var activeHandle: Grab = .upper
    private var link: CADisplayLink?
    private var animation: Animation?
    private var wheelCommit: DispatchWorkItem?
    private var trackingArea: NSTrackingArea?
    /// 显示值：阻尼跟随指针、越过端点时可被拉出范围；`value` 永远是夹在范围内、按规则量化过的对外值。
    private var shown: Double
    /// 拖动时指针对应的原始值（未夹、未量化）。
    private var target = 0.0
    /// 上一次发声时所在的刻度步序号；一次交互开始时归位，结束后清空。
    private var tickedStep: Int?
    private var lastTickTime: TimeInterval = 0
    private var tickDirection = 0
    /// 两声之间的最短间隔；刚反向时再多等一倍，快速来回搓不会连成一片。
    public static var tickInterval: TimeInterval = 0.035
    /// 惯性：松手速度（点 / 秒）达到阈值才滑，起速封顶，每帧乘以摩擦系数；封顶速度下总共只溜约 70 点。
    static let inertiaThreshold = 300.0
    static let inertiaCap = 900.0
    static let inertiaFriction = 0.78
    /// 当前画在轨道上的值（可能因阻尼落后于 `value`，或因回弹越出范围）。
    public var displayedValue: Double { shown }
    /// 全局音效开关（设置可接）；`configuration.sound` 决定单个滑块是否响。
    public static var soundsEnabled = true
    public static var tickPlayer: any CaliperTickPlaying = CaliperTickSound.shared

    private enum Grab { case single, lower, upper, both }
    private enum Animation { case follow, inertia(velocity: Double), spring(target: Double, velocity: Double), glide(target: Double) }

    public init(configuration: CaliperConfiguration, value: Double = 0, lower: Double = 0, upper: Double = 0, handles: Int = 1) {
        self.configuration = configuration
        self.handles = max(1, min(2, handles))
        self.value = value; lowerValue = lower; upperValue = upper; shown = value
        super.init(frame: CGRect(x: 0, y: 0, width: 240, height: configuration.height))
        if self.handles == 2 { self.configuration.track = .fixed }
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = false
        for shape in [minorLayer, midLayer, majorLayer, detentLayer, pointerLayer, upperPointerLayer] { shape.contentsScale = 2; shape.lineCap = .round }
        trackLayer.cornerRadius = configuration.size == .compact ? 5 : 8
        content.addSublayer(minorLayer); content.addSublayer(midLayer); content.addSublayer(majorLayer); content.addSublayer(detentLayer)
        for (bubble, text) in [(bubbleLayer, bubbleText), (upperBubbleLayer, upperBubbleText)] {
            bubble.cornerRadius = 5; text.alignmentMode = .center; text.contentsScale = 2; text.fontSize = 11
            bubble.addSublayer(text); bubble.isHidden = true
        }
        focusLayer.borderWidth = 1.5; focusLayer.cornerRadius = (configuration.size == .compact ? 5 : 8) + 2; focusLayer.isHidden = true
        for child in [trackLayer, rangeLayer, content, pointerLayer, upperPointerLayer, bubbleLayer, upperBubbleLayer, focusLayer] { layer?.addSublayer(child) }
        normalize()
        applyAppearance()
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
    }
    required init?(coder: NSCoder) { fatalError("不支持归档初始化") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { isEnabled }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: configuration.height) }

    // MARK: 值

    /// 外部设值：不触发回调，不做动画。
    public func setValue(_ newValue: Double) {
        let clamped = clamp(quantize(newValue))
        guard clamped != value || shown != clamped else { return }
        value = clamped; shown = clamped; place()
    }
    public func setRange(lower: Double, upper: Double) {
        lowerValue = clamp(quantize(lower)); upperValue = max(lowerValue + configuration.step, clamp(quantize(upper)))
        place()
    }
    public func reset() {
        guard handles == 1, let target = configuration.defaultValue else { return }
        beginEditing(); glide(to: clamp(quantize(target))) { [weak self] in self?.onReset?() }
    }
    public func format(_ v: Double) -> String {
        (configuration.decimals > 0 ? String(format: "%.\(configuration.decimals)f", v) : String(Int(v.rounded()))) + configuration.suffix
    }

    private func clamp(_ v: Double) -> Double { min(configuration.range.upperBound, max(configuration.range.lowerBound, v)) }
    private func quantize(_ v: Double) -> Double {
        if configuration.snapTo == .detents, let nearest = configuration.detents.min(by: { abs($0 - v) < abs($1 - v) }) { return nearest }
        let step = configuration.step
        return (v / step).rounded() * step
    }
    private func normalize() {
        value = clamp(quantize(value)); shown = value
        lowerValue = clamp(quantize(lowerValue)); upperValue = max(lowerValue + configuration.step, clamp(quantize(upperValue)))
    }

    // MARK: 几何

    private var inset: CGFloat { 14 }
    /// 范围跨度；上下界相等或非法时按 0 处理，调用方据此退化为"只有一个点"的静态刻度，绝不能算出 NaN / 无穷交给 CALayer。
    private var span: Double {
        let span = configuration.range.upperBound - configuration.range.lowerBound
        return span.isFinite && span > 0 ? span : 0
    }
    private var pxPerUnit: CGFloat {
        if configuration.track == .scroll { return configuration.pxPerUnit.isFinite && configuration.pxPerUnit > 0 ? CGFloat(configuration.pxPerUnit) : 1 }
        guard span > 0 else { return 1 }
        return max(0.000_1, (bounds.width - inset * 2) / CGFloat(span))
    }
    /// 刻度层内部坐标：值 → x；非法值落在起点。
    private func contentX(_ v: Double) -> CGFloat {
        let x = CGFloat(v - configuration.range.lowerBound) * pxPerUnit
        return x.isFinite ? x : 0
    }
    /// 视图坐标：值 → x。
    public func x(for v: Double) -> CGFloat { content.frame.minX + contentX(v) }
    public func value(atX x: CGFloat) -> Double {
        let value = configuration.range.lowerBound + Double((x - content.frame.minX) / pxPerUnit)
        return value.isFinite ? value : configuration.range.lowerBound
    }
    private var baseline: CGFloat { configuration.size == .compact ? bounds.height : (configuration.track == .fixed ? bounds.height - 18 : bounds.height - 14) }
    private var tickTop: CGFloat { baseline - (configuration.size == .compact ? 14 : 22) }

    public override func layout() {
        super.layout()
        if builtWidth != bounds.width { rebuild() } else { place() }
    }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearance() }
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for l in [minorLayer, midLayer, majorLayer, detentLayer, pointerLayer, upperPointerLayer, bubbleText, upperBubbleText] as [CALayer] { l.contentsScale = scale }
        labels.forEach { $0.contentsScale = scale }
    }

    private func applyAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let white = CaploNSColor.textPrimary
            trackLayer.backgroundColor = white.withAlphaComponent(0.045).cgColor
            minorLayer.strokeColor = white.withAlphaComponent(0.26).cgColor; minorLayer.lineWidth = 1
            midLayer.strokeColor = white.withAlphaComponent(0.44).cgColor; midLayer.lineWidth = 1
            majorLayer.strokeColor = white.withAlphaComponent(0.80).cgColor; majorLayer.lineWidth = 1.5
            detentLayer.fillColor = CaploNSColor.accent.cgColor
            rangeLayer.backgroundColor = CaploNSColor.accentSoft.cgColor
            for pointer in [pointerLayer, upperPointerLayer] { pointer.strokeColor = CaploNSColor.accent.cgColor; pointer.fillColor = CaploNSColor.accent.cgColor; pointer.lineWidth = 1.5 }
            for bubble in [bubbleLayer, upperBubbleLayer] { bubble.backgroundColor = CaploNSColor.accent.cgColor }
            for text in [bubbleText, upperBubbleText] { text.foregroundColor = CaploNSColor.primaryButtonText.cgColor }
            labels.forEach { $0.foregroundColor = white.withAlphaComponent(0.42).cgColor }
            focusLayer.borderColor = CaploNSColor.accent.cgColor
        }
    }

    /// 宽度或配置变化时重建刻度层；拖动只走 `place()`。
    private func rebuild() {
        guard bounds.width > 0 else { return }
        builtWidth = bounds.width
        normalize()
        let c = configuration, compact = c.size == .compact
        CATransaction.begin(); CATransaction.setDisableActions(true)
        trackLayer.cornerRadius = compact ? 5 : 8
        trackLayer.frame = compact ? bounds : CGRect(x: 0, y: tickTop - 4, width: bounds.width, height: baseline - tickTop + 8)
        let totalWidth = contentX(c.range.upperBound)
        content.frame = CGRect(x: 0, y: 0, width: totalWidth, height: bounds.height)
        // 刻度间隔：给定 tickStep，或 step 放粗到至少 4 点一格。
        var tick = c.tickStep ?? c.step
        if !(tick.isFinite && tick > 0) { tick = max(span, 1) }
        while tick * Double(pxPerUnit) < 4 { tick *= 2 }
        let minor = CGMutablePath(), mid = CGMutablePath(), major = CGMutablePath()
        labels.forEach { $0.removeFromSuperlayer() }; labels.removeAll()
        let detentsOnly = c.snapTo == .detents && !c.detents.isEmpty
        if !detentsOnly {
            let count = span > 0 ? Int((span / tick).rounded()) : 0
            for i in 0...max(0, count) {
                let v = c.range.lowerBound + Double(i) * tick
                let x = (contentX(v)).rounded() + 0.5
                let isMajor = abs(v / c.major - (v / c.major).rounded()) < 1e-6
                let isMid = !isMajor && abs(v / c.effectiveMid - (v / c.effectiveMid).rounded()) < 1e-6
                let length: CGFloat = compact ? (isMajor ? 12 : isMid ? 8 : 5) : (isMajor ? 22 : isMid ? 14 : 8)
                let path = isMajor ? major : isMid ? mid : minor
                path.move(to: CGPoint(x: x, y: baseline)); path.addLine(to: CGPoint(x: x, y: baseline - length))
                if isMajor, !compact { addLabel(format(v).replacingOccurrences(of: c.suffix, with: ""), at: x) }
            }
        }
        let detents = CGMutablePath()
        // 范围外的档位不画：视图不裁切，画了就会漏到轨道外面（时间线缩放的 0 档在短录制里低于"适合窗口"下限）。
        for d in c.detents where c.range.contains(d) {
            let x = contentX(d).rounded() + 0.5
            if detentsOnly {
                major.move(to: CGPoint(x: x, y: baseline)); major.addLine(to: CGPoint(x: x, y: baseline - (compact ? 12 : 22)))
                if !compact { addLabel(format(d), at: x) }
            }
            // 档位菱形：紧凑 5 点、常规 6 点见方，只是个标记，不能压过刻度。
            let y = compact ? baseline - 12 : tickTop - 2, half: CGFloat = compact ? 2.5 : 3
            detents.move(to: CGPoint(x: x, y: y - half)); detents.addLine(to: CGPoint(x: x + half, y: y)); detents.addLine(to: CGPoint(x: x, y: y + half)); detents.addLine(to: CGPoint(x: x - half, y: y)); detents.closeSubpath()
        }
        minorLayer.path = minor; midLayer.path = mid; majorLayer.path = major; detentLayer.path = detents.isEmpty ? nil : detents
        for shape in [minorLayer, midLayer, majorLayer, detentLayer] { shape.frame = content.bounds }
        // 游标：竖线 + 顶部一个小三角（紧凑 6×3、常规 8×4），只是个方向提示，不要压过刻度；路径以 x = 0 为中心，摆放只改 position。
        for pointer in [pointerLayer, upperPointerLayer] {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: compact ? 0 : tickTop - 6)); p.addLine(to: CGPoint(x: 0, y: baseline + (compact ? 0 : 2)))
            let half: CGFloat = compact ? 3 : 4, tall: CGFloat = compact ? 3 : 4
            let top: CGFloat = compact ? 0 : tickTop - 10
            p.move(to: CGPoint(x: -half, y: top)); p.addLine(to: CGPoint(x: half, y: top)); p.addLine(to: CGPoint(x: 0, y: top + tall)); p.closeSubpath()
            pointer.path = p; pointer.bounds = CGRect(x: -6, y: 0, width: 12, height: bounds.height); pointer.anchorPoint = CGPoint(x: 0.5, y: 0)
        }
        upperPointerLayer.isHidden = handles == 1; rangeLayer.isHidden = handles == 1
        if c.fades {
            let mask = fadeMask ?? CAGradientLayer()
            mask.startPoint = CGPoint(x: 0, y: 0.5); mask.endPoint = CGPoint(x: 1, y: 0.5)
            mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            mask.locations = [0, 0.28, 0.72, 1]
            fadeMask = mask
            // 渐隐只作用于刻度层：把遮罩挂在一个和视图同大的父层上。
            content.mask = nil; maskHost.mask = mask; mask.frame = bounds
        } else { maskHost.mask = nil }
        focusLayer.frame = bounds.insetBy(dx: -2, dy: -2)
        CATransaction.commit()
        applyAppearance()
        place()
    }
    /// 刻度层的父层：渐隐遮罩挂在这里，遮罩随视图而不是随刻度移动。
    /// 档位菱形在视图坐标里的总范围（测试用）；没有画任何档位时为 nil。
    public var detentMarkerBounds: CGRect? {
        guard let path = detentLayer.path, !path.isEmpty else { return nil }
        return path.boundingBox.offsetBy(dx: content.frame.minX, dy: content.frame.minY)
    }
    private lazy var maskHost: CALayer = {
        let host = CALayer(); host.frame = bounds
        layer?.insertSublayer(host, above: rangeLayer)
        content.removeFromSuperlayer(); host.addSublayer(content)
        return host
    }()
    private func addLabel(_ text: String, at x: CGFloat) {
        let label = CATextLayer()
        label.string = text; label.fontSize = 10; label.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        label.alignmentMode = .center; label.contentsScale = window?.backingScaleFactor ?? 2
        label.frame = CGRect(x: x - 30, y: baseline + 2, width: 60, height: 13)
        content.addSublayer(label); labels.append(label)
    }

    /// 只改位置：滚动轨道平移刻度层，固定轨道移动游标；气泡与区间高亮跟着走。
    private func place() {
        guard bounds.width > 0, builtWidth == bounds.width else { return }
        placedShown = shown
        let c = configuration
        CATransaction.begin(); CATransaction.setDisableActions(true)
        maskHost.frame = bounds; fadeMask?.frame = bounds
        var frame = content.frame
        frame.origin.x = c.track == .scroll ? bounds.width / 2 - contentX(shown) : inset
        content.frame = frame
        let on = hovered || dragging || isFocused
        if handles == 2 {
            pointerLayer.position = CGPoint(x: x(for: lowerValue), y: 0)
            upperPointerLayer.position = CGPoint(x: x(for: upperValue), y: 0)
            rangeLayer.frame = CGRect(x: x(for: lowerValue), y: trackLayer.frame.minY, width: max(0, x(for: upperValue) - x(for: lowerValue)), height: trackLayer.frame.height)
            placeBubble(bubbleLayer, bubbleText, at: x(for: lowerValue), text: format(lowerValue))
            placeBubble(upperBubbleLayer, upperBubbleText, at: x(for: upperValue), text: format(upperValue))
        } else {
            pointerLayer.position = CGPoint(x: x(for: shown), y: 0)
            var scale: CGFloat = 1
            if !dragging, c.magnet != .none {
                let stops = c.magnet == .major ? [(value / c.major).rounded() * c.major] : c.detents
                if stops.contains(where: { abs($0 - value) < 1e-6 }) { scale = 1.15 }
            }
            pointerLayer.transform = CATransform3DMakeScale(scale, scale, 1)
            placeBubble(bubbleLayer, bubbleText, at: x(for: shown), text: format(value))
        }
        for pointer in [pointerLayer, upperPointerLayer] { pointer.opacity = on ? 1 : 0.9 }
        CATransaction.commit()
        updateAccessibility()
    }
    private func placeBubble(_ bubble: CALayer, _ text: CATextLayer, at x: CGFloat, text string: String) {
        guard configuration.size == .regular, configuration.showValue == .bubble else { bubble.isHidden = true; return }
        bubble.isHidden = false
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let width = (string as NSString).size(withAttributes: [.font: font]).width + 12
        let scale: CGFloat = dragging ? 1.05 : 1
        text.string = string; text.font = font
        bubble.bounds = CGRect(x: 0, y: 0, width: width, height: 16)
        bubble.position = CGPoint(x: min(bounds.width - width / 2 - 2, max(width / 2 + 2, x)), y: 10)
        bubble.transform = CATransform3DMakeScale(scale, scale, 1)
        text.frame = CGRect(x: 0, y: 1, width: width, height: 14)
    }

    // MARK: 交互

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); trackingArea = area
    }
    public override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .resizeLeftRight) } }
    public override func mouseEntered(with event: NSEvent) { hovered = true; place() }
    public override func mouseExited(with event: NSEvent) { hovered = false; place() }
    private var isFocused: Bool { window?.firstResponder === self }
    /// 鼠标点进来不画焦点环（`mouseDown` 先把标志压下），键盘 Tab 进来才画；用过一次后恢复默认。
    /// 焦点环：只要持有焦点就画，鼠标点进来也画——滚轮只对有焦点的滑块生效，用户必须一眼看出焦点在哪。
    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        focusLayer.isHidden = !ok
        if ok { CaliperFocusWatcher.track(self) }
        place(); return ok
    }
    public override func resignFirstResponder() -> Bool {
        focusLayer.isHidden = true
        let ok = super.resignFirstResponder()
        if ok { CaliperFocusWatcher.untrack(self) }
        place(); return ok
    }
    /// 测试用：焦点环是否可见。
    public var isShowingFocusRing: Bool { !focusLayer.isHidden }
    /// 测试用：当前被焦点监听记住的滑块。
    public static var focusedForTesting: CaliperView? { CaliperFocusWatcher.focused }

    /// 阻尼：显示值按时间常数 τ = 0.12 秒 × damping 指数逼近指针位置；区间滑块与"减少动态效果"下即时跟手。
    private var damped: Bool { !reduceMotion && configuration.damping > 0 && handles == 1 }
    private var timeConstant: Double { 0.12 * min(1, max(0, configuration.damping)) }
    private var soundEnabled: Bool { Self.soundsEnabled && handles == 1 && (configuration.sound ?? (configuration.track == .scroll)) }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount == 2 { reset(); return }
        stopAnimation()
        window?.makeFirstResponder(self)
        let x = convert(event.locationInWindow, from: nil).x
        dragging = true; lastX = x; lastTime = event.timestamp; velocity = 0
        beginEditing()
        if handles == 2 {
            let xl = self.x(for: lowerValue), xh = self.x(for: upperValue)
            grab = (x > xl + 10 && x < xh - 10) ? .both : (abs(x - xl) <= abs(x - xh) ? .lower : .upper)
            if grab != .both { activeHandle = grab }
            grabStart = (x, lowerValue, upperValue)
        } else if configuration.track == .fixed {
            target = value(atX: x)
            if damped { startAnimation(.follow) } else { shown = clamp(target); commitShown() }
        } else {
            grabStart = (x, shown, 0); target = shown
            if damped { startAnimation(.follow) }
        }
        place()
    }
    public override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let x = convert(event.locationInWindow, from: nil).x, dx = x - lastX
        let dt = max(0.001, event.timestamp - lastTime)
        if handles == 2 {
            let dv = Double(x - grabStart.x) / Double(pxPerUnit)
            switch grab {
            case .lower: lowerValue = clamp(min(quantize(grabStart.lo + dv), upperValue - configuration.step))
            case .upper: upperValue = clamp(max(quantize(grabStart.hi + dv), lowerValue + configuration.step))
            default:
                let span = grabStart.hi - grabStart.lo
                let lo = min(max(quantize(grabStart.lo + dv), configuration.range.lowerBound), configuration.range.upperBound - span)
                lowerValue = lo; upperValue = lo + span
            }
            emitChange(); place()
        } else if configuration.track == .scroll {
            target = grabStart.lo - Double(x - grabStart.x) / Double(pxPerUnit)
            velocity = 0.8 * velocity + 0.2 * (Double(dx) / dt)   // 点 / 秒
            if damped { if animation == nil { startAnimation(.follow) } } else { shown = clamp(target); commitShown() }
        } else {
            target = value(atX: x)
            if damped { if animation == nil { startAnimation(.follow) } } else { shown = clamp(target); commitShown() }
        }
        lastX = x; lastTime = event.timestamp
    }
    public override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        if handles == 2 { place(); endEditing(); return }
        if configuration.track == .fixed { glide(to: clamp(quantize(damped ? target : shown))); return }
        // 被拉出范围：先弹回端点，再按吸附规则落定。
        if shown < configuration.range.lowerBound || shown > configuration.range.upperBound {
            startAnimation(.spring(target: clamp(shown), velocity: 0)); return
        }
        // 惯性压到最小：只有甩得够快才滑，起速封顶、四五帧内衰减掉，最多再溜几十个点。
        if configuration.inertia, !reduceMotion, abs(velocity) >= Self.inertiaThreshold, configuration.snapTo != .detents {
            startAnimation(.inertia(velocity: max(-Self.inertiaCap, min(Self.inertiaCap, velocity))))
        } else { settle() }
    }
    /// 滚轮只在滑块持有键盘焦点时生效（点过或 Tab 到它）；否则把事件交回上层，让面板照常滚动，
    /// 避免滚动面板时鼠标扫过滑块把参数改掉。
    public var wheelRequiresFocus = true

    public override func scrollWheel(with event: NSEvent) {
        guard isEnabled else { super.scrollWheel(with: event); return }
        if wheelRequiresFocus, !isFocused { super.scrollWheel(with: event); return }
        stopAnimation()
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        guard delta != 0 else { return }
        if !isInteracting { beginEditing() }
        let units = configuration.step * Double(delta > 0 ? 1 : -1) * Double(max(1, Int((abs(delta) / 12).rounded())))
        nudge(by: units)
        wheelCommit?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.endEditing() } }
        wheelCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }
    public override func keyDown(with event: NSEvent) {
        guard isEnabled else { super.keyDown(with: event); return }
        let multiplier = event.modifierFlags.contains(.shift) ? 10.0 : 1
        switch event.keyCode {
        case 123, 125: step(-1, multiplier: multiplier)
        case 124, 126: step(1, multiplier: multiplier)
        case 115: jump(to: configuration.range.lowerBound)
        case 119: jump(to: configuration.range.upperBound)
        case 53: window?.makeFirstResponder(nil)   // Esc：交出焦点
        default: super.keyDown(with: event); return
        }
    }

    private func step(_ direction: Double, multiplier: Double) {
        stopAnimation(); beginEditing()
        if configuration.snapTo == .detents, handles == 1, !configuration.detents.isEmpty {
            let sorted = configuration.detents.sorted()
            let index = sorted.firstIndex(where: { abs($0 - value) < 1e-6 }) ?? 0
            shown = sorted[max(0, min(sorted.count - 1, index + Int(direction)))]
            commitShown()
        } else { nudge(by: direction * configuration.step * multiplier) }
        endEditing()
    }
    private func jump(to goal: Double) {
        stopAnimation(); beginEditing()
        if handles == 2 { moveActiveHandle(to: goal); emitChange(); place() } else { shown = clamp(quantize(goal)); commitShown() }
        endEditing()
    }
    private func nudge(by units: Double) {
        if handles == 2 { moveActiveHandle(to: (activeHandle == .lower ? lowerValue : upperValue) + units); emitChange(); place() }
        else { shown = clamp(quantize(shown + units)); commitShown() }
    }
    private func moveActiveHandle(to goal: Double) {
        if activeHandle == .lower { lowerValue = clamp(min(quantize(goal), upperValue - configuration.step)) }
        else { upperValue = clamp(max(quantize(goal), lowerValue + configuration.step)) }
    }

    /// 把显示值折算成对外值并通知：两种轨道都按步量化——拖动期间每帧只有跨过一个刻度步才会对外吐新值，
    /// 面板、模型和播放器换合成的次数按刻度计而不是按帧计。显示值没动就不重摆图层。
    private func commitShown() {
        let next = clamp(quantize(shown))
        if next != value { value = next; emitChange() }
        noteStep()
        if shown != placedShown { place() }
    }
    private var placedShown = Double.nan

    /// 越过范围端点后的显示位置：拉得越远阻力越大，最多拉出 48 点。
    private func rubberBand(_ raw: Double) -> Double {
        let px = Double(pxPerUnit), lower = configuration.range.lowerBound, upper = configuration.range.upperBound
        let limit = 48.0
        func stretch(_ excess: Double) -> Double { (1 - 1 / (excess * 0.55 / limit + 1)) * limit }
        if raw < lower { return lower - stretch((lower - raw) * px) / px }
        if raw > upper { return upper + stretch((raw - upper) * px) / px }
        return raw
    }

    // MARK: 音效

    /// 滚动轨道每跨过一个刻度步发一声，只有一种声音。轻度防抖：两声至少隔 `tickInterval`，刚反向时再多等一倍。
    private func noteStep() {
        let index = stepIndex(of: shown)
        guard let previous = tickedStep else { tickedStep = index; return }
        guard index != previous else { return }
        let direction = index > previous ? 1 : -1
        tickedStep = index
        guard soundEnabled else { return }
        let now = CACurrentMediaTime()
        let reversed = tickDirection != 0 && direction != tickDirection
        tickDirection = direction
        guard now - lastTickTime >= (reversed ? Self.tickInterval * 2 : Self.tickInterval) else { return }
        lastTickTime = now
        Self.tickPlayer.tick()
    }
    private func stepIndex(of v: Double) -> Int {
        let ratio = clamp(v) / configuration.step
        return ratio.isFinite && abs(ratio) < 1e15 ? Int(ratio.rounded()) : 0
    }

    // MARK: 动画：跟随、惯性、回弹与吸附

    private func settle() {
        let c = configuration
        var goal = quantize(shown)
        if c.magnet == .major {
            let m = (shown / c.major).rounded() * c.major
            if abs(m - shown) <= c.major * 0.18 { goal = m }
        } else if c.magnet == .detents, let d = c.detents.min(by: { abs($0 - shown) < abs($1 - shown) }), abs(d - shown) <= c.major * 0.18 {
            goal = d
        }
        glide(to: clamp(goal))
    }
    private func glide(to goal: Double, completion: (() -> Void)? = nil) {
        if reduceMotion || abs(goal - shown) < 1e-9 {
            shown = goal; commitShown(); endEditing(); completion?(); return
        }
        glideCompletion = completion
        startAnimation(.glide(target: goal))
    }
    private var glideCompletion: (() -> Void)?
    private func startAnimation(_ animation: Animation) {
        self.animation = animation
        if link == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }
    private func stopAnimation() { link?.invalidate(); link = nil; animation = nil }
    @objc private func tick(_ link: CADisplayLink) {
        advance(by: max(0.001, min(0.05, link.targetTimestamp - link.timestamp)))
    }
    /// 测试用：当前是否有动画（显示链路）在跑。
    public var isAnimatingForTesting: Bool { animation != nil }
    /// 测试用：不经显示链路，按 60 帧 / 秒推进当前动画。
    public func advanceAnimationForTesting(by seconds: Double) {
        var remaining = seconds
        while remaining > 0, animation != nil {
            let dt = min(1.0 / 60, remaining)
            advance(by: dt); remaining -= dt
        }
    }
    private func advance(by dt: Double) {
        guard let animation else { stopAnimation(); return }
        let px = Double(pxPerUnit)
        let lower = configuration.range.lowerBound, upper = configuration.range.upperBound
        switch animation {
        case .follow:
            let goal = configuration.track == .scroll ? rubberBand(target) : clamp(target)
            shown += (goal - shown) * (1 - exp(-dt / max(0.001, timeConstant)))
            if abs(goal - shown) * px < 0.05 { shown = goal }
            commitShown()
            // 已经贴上指针就停掉显示链路，鼠标不动时不做任何每帧工作；指针再动由 mouseDragged 重启。
            if shown == goal { stopAnimation() }
        case .inertia(var v):
            v *= pow(Self.inertiaFriction, dt * 60)
            shown -= v * dt / px
            if shown < lower || shown > upper {
                // 撞到端点：带着剩余速度进入弹簧，轻微弹出再回弹。
                let bound = clamp(shown); shown = bound
                self.animation = .spring(target: bound, velocity: -v / px)
                commitShown(); return
            }
            commitShown()
            if abs(v) < 20 { stopAnimation(); settle(); return }
            self.animation = .inertia(velocity: v)
        case .spring(let goal, let v):
            // 以像素为单位的弹簧（ζ = 0.8），只有轻微过冲。
            let stiffness = 420.0, friction = 2 * sqrt(stiffness) * 0.8
            var offset = (shown - goal) * px, speed = v * px
            speed += (-stiffness * offset - friction * speed) * dt
            offset += speed * dt
            shown = goal + offset / px
            commitShown()
            if abs(offset) < 0.1, abs(speed) < 2 { shown = goal; commitShown(); stopAnimation(); settle(); return }
            self.animation = .spring(target: goal, velocity: speed / px)
        case .glide(let goal):
            let d = goal - shown
            if abs(d) < 0.002 * max(1, configuration.step) {
                shown = goal; commitShown(); stopAnimation(); endEditing()
                glideCompletion?(); glideCompletion = nil
            } else {
                shown += d * min(1, 0.25 * dt * 60); commitShown()
            }
        }
    }

    // MARK: 回调与辅助功能

    /// 防抖计时跨交互延续：键盘连按每次都是新交互，也不能连成一片。
    private func beginEditing() { guard !isInteracting else { return }; isInteracting = true; tickedStep = stepIndex(of: shown); onEditingChanged?(true) }
    private func endEditing() { guard isInteracting else { return }; isInteracting = false; tickedStep = nil; onEditingChanged?(false) }
    private func emitChange() { if handles == 2 { onRangeChange?(lowerValue, upperValue) } else { onChange?(value) } }

    private func updateAccessibility() {
        setAccessibilityValue(handles == 2 ? String(localized: "\(format(lowerValue)) 到 \(format(upperValue))") : format(value))
        setAccessibilityMinValue(configuration.range.lowerBound); setAccessibilityMaxValue(configuration.range.upperBound)
    }
    public override func accessibilityPerformIncrement() -> Bool { step(1, multiplier: 1); return true }
    public override func accessibilityPerformDecrement() -> Bool { step(-1, multiplier: 1); return true }
}

// MARK: - SwiftUI 包装

/// 单值卡尺滑块；`onEditingChanged` 与 `StudioSlider` 语义一致：按下 / 滚轮开始为 true，松手、吸附完成或滚轮停顿后为 false。
public struct CaliperSlider: NSViewRepresentable {
    @Binding private var value: Double
    private let configuration: CaliperConfiguration
    private let editing: (Bool) -> Void
    private let title: String
    @Environment(\.isEnabled) private var enabled

    public init(_ title: String = "", value: Binding<Double>, configuration: CaliperConfiguration, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title; _value = value; self.configuration = configuration; editing = onEditingChanged
    }

    public func makeNSView(context: Context) -> CaliperView {
        let view = CaliperView(configuration: configuration, value: value)
        view.setAccessibilityLabel(title)
        context.coordinator.attach(view, value: $value, editing: editing)
        return view
    }
    public func updateNSView(_ view: CaliperView, context: Context) {
        context.coordinator.attach(view, value: $value, editing: editing)
        view.configuration = configuration
        view.isEnabled = enabled
        if !view.isInteracting { view.setValue(value) }
    }
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: CaliperView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: configuration.height)
    }
    public func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor public final class Coordinator {
        func attach(_ view: CaliperView, value: Binding<Double>, editing: @escaping (Bool) -> Void) {
            view.onChange = { value.wrappedValue = $0 }
            view.onEditingChanged = editing
            view.onReset = {}
        }
    }
}

/// 区间卡尺滑块：两个游标截出 `lower...upper`。
public struct CaliperRangeSlider: NSViewRepresentable {
    @Binding private var lower: Double
    @Binding private var upper: Double
    private let configuration: CaliperConfiguration
    private let editing: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled

    public init(lower: Binding<Double>, upper: Binding<Double>, configuration: CaliperConfiguration, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _lower = lower; _upper = upper; self.configuration = configuration; editing = onEditingChanged
    }
    public func makeNSView(context: Context) -> CaliperView {
        let view = CaliperView(configuration: configuration, lower: lower, upper: upper, handles: 2)
        context.coordinator.attach(view, lower: $lower, upper: $upper, editing: editing)
        return view
    }
    public func updateNSView(_ view: CaliperView, context: Context) {
        context.coordinator.attach(view, lower: $lower, upper: $upper, editing: editing)
        view.configuration = configuration; view.isEnabled = enabled
        if !view.isInteracting { view.setRange(lower: lower, upper: upper) }
    }
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: CaliperView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: configuration.height)
    }
    public func makeCoordinator() -> Coordinator { Coordinator() }
    @MainActor public final class Coordinator {
        func attach(_ view: CaliperView, lower: Binding<Double>, upper: Binding<Double>, editing: @escaping (Bool) -> Void) {
            view.onRangeChange = { lower.wrappedValue = $0; upper.wrappedValue = $1 }
            view.onEditingChanged = editing
        }
    }
}

/// 属性面板参数行：标签左、"重置"与数值右，下面一条紧凑卡尺；与 `LabeledSlider` 同一接口，可直接替换。
public struct LabeledCaliper: View {
    private let title: String
    @Binding private var value: Double
    private let configuration: CaliperConfiguration
    private let format: (Double) -> String
    private let editing: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled

    public init(_ title: String, value: Binding<Double>, configuration: CaliperConfiguration,
                format: @escaping (Double) -> String = { String(format: "%.0f", $0) },
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title; _value = value
        var config = configuration; config.size = .compact; config.showValue = .none
        self.configuration = config; self.format = format; editing = onEditingChanged
    }

    private var showsReset: Bool {
        guard let defaultValue = configuration.defaultValue else { return false }
        return abs(value - defaultValue) > 0.0001
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CaploMetrics.Spacing.xs) {
            HStack(spacing: CaploMetrics.Spacing.s) {
                Text(title).font(CaploFont.body).foregroundStyle(CaploColor.textPrimary)
                Spacer(minLength: 0)
                if showsReset, let defaultValue = configuration.defaultValue {
                    Button("重置") { editing(true); value = defaultValue; editing(false) }
                        .buttonStyle(.plain).font(CaploFont.caption).foregroundStyle(CaploColor.accent)
                        .accessibilityLabel("重置\(title)")
                }
                Text(format(value)).font(CaploFont.value).foregroundStyle(CaploColor.textSecondary)
                    .frame(minWidth: 32, alignment: .trailing)
            }
            CaliperSlider(title, value: $value, configuration: configuration, onEditingChanged: editing)
                .frame(height: configuration.height)
        }
        .opacity(enabled ? 1 : 0.5)
    }
}

/// 全应用只装一个点击监听，记住当前持有焦点的卡尺：点到它之外就在下一轮运行循环里交出焦点
/// （若点击已经把焦点交给了别的控件则什么都不做）。之前每个滑块各装各拆监听，在事件分发中途增删监听表，
/// 两个滑块来回切换几次后监听残留、越积越多，焦点开始失灵并拖慢每次点击。
@MainActor
private enum CaliperFocusWatcher {
    private static var monitor: Any?
    private(set) static weak var focused: CaliperView?

    static func track(_ view: CaliperView) {
        focused = view
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            let target = event.window, location = event.locationInWindow
            MainActor.assumeIsolated {
                guard let view = focused, let window = view.window, target === window,
                      !view.bounds.contains(view.convert(location, from: nil)) else { return }
                // 用运行循环而不是主队列排队：主线程当前的调度块结束前主队列不会再派活，运行循环的下一轮却一定会跑到。
                RunLoop.main.perform { MainActor.assumeIsolated { if window.firstResponder === view { window.makeFirstResponder(nil) } } }
            }
            return event
        }
    }
    static func untrack(_ view: CaliperView) { if focused === view { focused = nil } }
}

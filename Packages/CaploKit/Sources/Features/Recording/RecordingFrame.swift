import AppKit
import QuartzCore
import CaploDesignSystem

/// 全屏模式的取景提示：进入录制条时四个角就出现淡红色 L 形标记（表示"这块屏幕将被录"），
/// 录制真正开始那一刻整屏浮现一圈描边并在 1 秒内淡出，之后四角常驻、暂停时更淡。
/// 面板置顶、点击穿透；全屏采集过滤器排除了本应用的全部窗口，所以不会录进片子。
@MainActor
enum RecordingFrameSession {
    private static var panel: NSPanel?
    private static var view: RecordingFrameView?

    static var isShowing: Bool { panel != nil }

    private static var screen: NSScreen?

    /// 显示四角标记；同一块屏幕上重复调用不重建（避免闪一下）。
    static func begin(on screen: NSScreen) {
        if isShowing, self.screen == screen, panel?.frame == screen.frame { return }
        dismiss()
        self.screen = screen
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = StudioLevel.overlay
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        // 不可共享：四角标记只给用户看，不进片子。
        panel.sharingType = .none
        let view = RecordingFrameView(frame: CGRect(origin: .zero, size: screen.frame.size))
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel; self.view = view
        view.showCorners(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// 录制开始的一次性整屏描边。
    static func pulse() { view?.pulse(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) }

    static func setPaused(_ paused: Bool) { view?.paused = paused }

    static func dismiss() {
        panel?.orderOut(nil)
        panel = nil; view = nil; screen = nil
    }
}

/// 两层图形：整屏描边只在开始时出现一次；四角标记常驻。几何随视图尺寸更新，不做逐帧重绘。
@MainActor
final class RecordingFrameView: NSView {
    static let cornerLength: CGFloat = 28
    static let cornerInset: CGFloat = 14
    static let cornerOpacity: Float = 0.7
    static let pausedOpacity: Float = 0.3
    let pulseLayer = CAShapeLayer()
    let cornersLayer = CAShapeLayer()
    var paused = false {
        didSet {
            guard paused != oldValue else { return }
            CATransaction.begin(); CATransaction.setAnimationDuration(0.2)
            cornersLayer.opacity = paused ? Self.pausedOpacity : Self.cornerOpacity
            CATransaction.commit()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        for shape in [pulseLayer, cornersLayer] {
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            layer?.addSublayer(shape)
        }
        pulseLayer.lineWidth = 6
        pulseLayer.opacity = 0
        cornersLayer.lineWidth = 3
        cornersLayer.opacity = 0
        applyAppearance()
        updatePaths()
    }
    required init?(coder: NSCoder) { fatalError("不支持归档初始化") }

    override func layout() { super.layout(); updatePaths() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearance() }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        pulseLayer.contentsScale = scale; cornersLayer.contentsScale = scale
    }

    private func applyAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // 录制语义用淡红（record 令牌），与 REC 按钮、播放头同一色相。
            pulseLayer.strokeColor = CaploNSColor.record.cgColor
            cornersLayer.strokeColor = CaploNSColor.record.cgColor
        }
    }

    private func updatePaths() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pulseLayer.frame = bounds; cornersLayer.frame = bounds
        pulseLayer.path = CGPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), cornerWidth: 10, cornerHeight: 10, transform: nil)
        cornersLayer.path = Self.cornersPath(in: bounds)
        CATransaction.commit()
    }

    /// 四个角各一段 L 形：从角点沿两边各伸出 `cornerLength`。
    static func cornersPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let inset = cornerInset, length = cornerLength
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX + inset, y: rect.minY + inset), 1, 1),
            (CGPoint(x: rect.maxX - inset, y: rect.minY + inset), -1, 1),
            (CGPoint(x: rect.minX + inset, y: rect.maxY - inset), 1, -1),
            (CGPoint(x: rect.maxX - inset, y: rect.maxY - inset), -1, -1),
        ]
        for (point, dx, dy) in corners {
            path.move(to: CGPoint(x: point.x, y: point.y + dy * length))
            path.addLine(to: point)
            path.addLine(to: CGPoint(x: point.x + dx * length, y: point.y))
        }
        return path
    }

    /// 四角标记淡入（0.3 秒）；"减少动态效果"时直接显示。
    func showCorners(reduceMotion: Bool) {
        if reduceMotion {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            cornersLayer.opacity = Self.cornerOpacity
            CATransaction.commit()
            return
        }
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0; appear.toValue = Self.cornerOpacity; appear.duration = 0.3
        cornersLayer.opacity = Self.cornerOpacity
        cornersLayer.add(appear, forKey: "appear")
    }

    /// 开始脉冲：整屏描边从 1 淡到 0（0.9 秒）；"减少动态效果"时不闪。
    func pulse(reduceMotion: Bool) {
        guard !reduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.9
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulseLayer.opacity = 0
        pulseLayer.add(fade, forKey: "pulse")
    }
}

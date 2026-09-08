import SwiftUI
import AppKit
import CaploDesignSystem

// MARK: - 目标登记

/// 首次使用引导要高亮的控件：`ModePickerView` 里用 `.onboardingTarget(id)` 登记，引导层按需读它们的屏幕位置。
/// 登记的是真实 NSView（贴在控件背后的透明锚点），位置换算不依赖 SwiftUI 坐标空间的约定。
@MainActor
final class OnboardingTargets {
    static let shared = OnboardingTargets()
    private struct Entry { weak var view: NSView? }
    private var entries: [String: Entry] = [:]

    func register(_ id: String, view: NSView) { entries[id] = Entry(view: view) }
    func unregister(_ id: String, view: NSView) { if entries[id]?.view === view { entries[id] = nil } }

    /// 目标在屏幕坐标里的位置；控件不在可见窗口里时为 nil。
    func screenRect(_ id: String) -> CGRect? {
        guard let view = entries[id]?.view, let window = view.window, window.isVisible else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct OnboardingAnchor: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> AnchorView { let view = AnchorView(); view.id = id; return view }
    func updateNSView(_ view: AnchorView, context: Context) { view.id = id }

    final class AnchorView: NSView {
        var id = "" { didSet { if window != nil { OnboardingTargets.shared.register(id, view: self) } } }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { OnboardingTargets.shared.register(id, view: self) } else { OnboardingTargets.shared.unregister(id, view: self) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// 把这个视图登记为引导目标；锚点贴在视图背后，不参与点击。
    func onboardingTarget(_ id: String) -> some View { background(OnboardingAnchor(id: id)) }
}

// MARK: - 步骤

struct OnboardingStep: Equatable {
    let target: String
    let title: String
    let body: String
    /// 聚光灯比目标外扩多少。
    var padding: CGFloat = 4
    var radius: CGFloat = 12
    var last = false
}

// MARK: - 引导会话

/// 首次打开录制方式条时的分步引导：整屏压暗，聚光灯逐个挖空浮动条上的控件，提示卡停在聚光灯上方。
/// 点聚光灯、点"下一步"、按 → / 回车前进，← 后退，Esc、"跳过"或点遮罩任意其他位置结束；看完或跳过后记住，不再出现。
/// 逃生口不依赖键盘或本应用在前台：点遮罩即结束；目标两秒内找不到也自行撤掉。
/// 方式条收起时（选了录制方式、⌘N 关闭）随之撤掉，但不算看过，下次还会出现。
@MainActor
final class OnboardingTour {
    private(set) static var current: OnboardingTour?
    /// 测试里换成独立的 suite。
    static var defaults: UserDefaults = .standard
    static let seenKey = "onboarding.modePickerSeen"
    static var hasSeen: Bool {
        get { defaults.bool(forKey: seenKey) }
        set { defaults.set(newValue, forKey: seenKey) }
    }

    static let steps: [OnboardingStep] = [
        OnboardingStep(target: "bar", title: "欢迎使用 Caplo", body: "这条浮动条就是全部入口。选一种录制方式就能开始，录完自动进入编辑器。", padding: 10, radius: 20),
        OnboardingStep(target: "display", title: "录整个屏幕", body: "有多台显示器时会先问录哪一块。开始录制时屏幕四角会打上标记，不会挡住内容。"),
        OnboardingStep(target: "region", title: "框一块区域", body: "拖出范围后录制条会贴在框的下方，位置和大小随时能改，录制中也看得到边界。"),
        OnboardingStep(target: "window", title: "只录一个窗口", body: "点选窗口后其余部分压暗，被选中的窗口照常操作。窗口移动时录制条会跟着走。"),
        OnboardingStep(target: "recent", title: "回到最近的录制", body: "打开项目中心，继续编辑上一段，或者直接导出。"),
        OnboardingStep(target: "settings", title: "设置", body: "帧率、麦克风降噪、摄像头格式和快捷键都在这里。录制时也能从齿轮菜单打开。"),
        OnboardingStep(target: "bar", title: "准备好了", body: "选一种方式开始第一次录制吧。这个引导以后可以在设置里重新打开。", padding: 10, radius: 20, last: true),
    ]

    /// 方式条显示后调用：没看过才开始。
    static func beginIfNeeded() {
        guard !hasSeen, current == nil else { return }
        begin()
    }
    static func begin() {
        dismiss()
        current = OnboardingTour()
    }
    /// 撤掉但不记为看过。
    static func dismiss() {
        current?.tearDown()
        current = nil
    }
    static func reset() { hasSeen = false }

    private(set) var index = 0
    var step: OnboardingStep { Self.steps[index] }
    /// 当前聚光灯（屏幕坐标）；目标还没布局好时为 nil。供测试。
    private(set) var spotlight: CGRect?

    private var panels: [(screen: NSScreen, panel: NSPanel, shade: OnboardingShadeView)] = []
    private let tipState = OnboardingTipState()
    private var tipHost: FirstMouseHostingView<OnboardingTipView>?
    private var timer: Timer?
    private var keyMonitor: Any?
    private var pendingAnimation = false
    /// 目标持续找不到（方式条被收起或没布局出来）的起始时刻：超过两秒就自行撤掉，绝不让一层空遮罩挡住整个屏幕。
    private var missingSince: Date?
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private init() {
        tipState.count = Self.steps.count
        rebuildPanels()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 只把键码与修饰键带进主线程闭包，NSEvent 本身不可跨隔离域。
            let code = event.keyCode, command = event.modifierFlags.contains(.command)
            let consumed = MainActor.assumeIsolated { self?.handle(keyCode: code, command: command) ?? false }
            return consumed ? nil : event
        }
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        pendingAnimation = false
        // 按键监视器只收本应用的事件：引导一开始就把本应用带到前台，Esc / 方向键才送得到。
        NSApp.activate(ignoringOtherApps: true)
        tick()
    }

    private func tearDown() {
        timer?.invalidate(); timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        tipHost?.removeFromSuperview(); tipHost = nil
        for entry in panels { entry.panel.orderOut(nil); entry.panel.contentView = nil }
        panels.removeAll()
    }

    // MARK: 步进

    func next() { if step.last { finish() } else { go(index + 1) } }
    func back() { go(index - 1) }
    func go(_ target: Int) {
        let clamped = max(0, min(Self.steps.count - 1, target))
        guard clamped != index else { return }
        index = clamped
        pendingAnimation = true
        tick()
    }
    /// 看完或跳过：记住，撤掉。
    func finish() {
        Self.hasSeen = true
        Self.dismiss()
    }

    /// 返回是否吃掉这次按键。⌘ 组合键（⌘Q、⌘, 等）照常放行；其余按键在引导期间不落到方式条上，数字键不会误选方式。
    func handle(keyCode: UInt16, command: Bool) -> Bool {
        if command { return false }
        switch keyCode {
        case 124, 36, 76, 49: next()      // → 回车 小键盘回车 空格
        case 123: back()                  // ←
        case 53: finish()                 // Esc
        default: break
        }
        return true
    }

    // MARK: 覆盖层

    private func rebuildPanels() {
        for entry in panels { entry.panel.orderOut(nil); entry.panel.contentView = nil }
        panels = NSScreen.screens.map { screen in
            let panel = OnboardingPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            // 在方式条（.floating）之上：方式条透过挖空处露出来，点击落在引导层上，不会误触方式条。
            panel.level = StudioLevel.overlay
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            panel.hidesOnDeactivate = false
            panel.isExcludedFromWindowsMenu = true
            panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            // 引导从不与录制同时存在，不必从采集里排除；保留默认共享类型，屏幕截图也能看到它，便于核对。
            let shade = OnboardingShadeView(frame: CGRect(origin: .zero, size: screen.frame.size))
            shade.onSpotlightClick = { [weak self] in self?.next() }
            // 点聚光灯和提示卡之外的任何地方都直接结束：鼠标事件不依赖本应用在前台，这是永远可用的逃生口。
            shade.onOutsideClick = { [weak self] in self?.finish() }
            shade.onKey = { [weak self] code, command in self?.handle(keyCode: code, command: command) ?? false }
            panel.contentView = shade
            panel.initialFirstResponder = shade
            return (screen, panel, shade)
        }
    }

    private func tick() {
        if panels.map(\.screen.frame) != NSScreen.screens.map(\.frame) { rebuildPanels() }
        guard let target = OnboardingTargets.shared.screenRect(step.target) else {
            // 目标还没布局好或方式条已收起：短暂等待；超过两秒仍找不到就自行撤掉，不让空遮罩挡住屏幕。
            let since = missingSince ?? Date(); missingSince = since
            if Date().timeIntervalSince(since) > 2 { Self.dismiss(); return }
            spotlight = nil
            for entry in panels { entry.shade.set(hole: nil, radius: 0, animated: false); if !entry.panel.isVisible { entry.panel.orderFrontRegardless() } }
            tipHost?.isHidden = true
            return
        }
        missingSince = nil
        let spot = target.insetBy(dx: -step.padding, dy: -step.padding)
        let animated = pendingAnimation && !reduceMotion
        let changed = spot != spotlight
        spotlight = spot
        let active = panels.first { $0.screen.frame.contains(CGPoint(x: spot.midX, y: spot.midY)) } ?? panels.first { $0.screen.frame.intersects(spot) } ?? panels.first
        for entry in panels {
            let local = spot.offsetBy(dx: -entry.screen.frame.minX, dy: -entry.screen.frame.minY)
            entry.shade.set(hole: entry.screen === active?.screen ? local : nil, radius: step.radius, animated: animated)
            if !entry.panel.isVisible { entry.panel.orderFrontRegardless() }
        }
        // 聚光灯所在的那层成为键窗口：Esc 与方向键既走按键监视器，也走遮罩视图自己的响应链，两条路都通。
        if let active, !active.panel.isKeyWindow { active.panel.makeKey(); active.panel.makeFirstResponder(active.shade) }
        if let active, changed || pendingAnimation || tipHost == nil { placeTip(in: active, spot: spot, animated: animated) }
        pendingAnimation = false
    }

    /// 提示卡放在聚光灯上方、水平对准目标中心，左右钳在可见区域内；上方放不下就放到下方，箭头翻到上沿。
    static func tipFrame(spot: CGRect, size: CGSize, visible: CGRect) -> (frame: CGRect, arrowX: CGFloat, below: Bool) {
        let margin: CGFloat = 12, gap: CGFloat = 16
        var x = spot.midX - size.width / 2
        x = min(max(visible.minX + margin, x), visible.maxX - size.width - margin)
        var y = spot.maxY + gap
        var below = false
        if y + size.height > visible.maxY { y = spot.minY - gap - size.height; below = true }
        let arrowX = min(max(20, spot.midX - x), size.width - 20)
        return (CGRect(x: x, y: y, width: size.width, height: size.height), arrowX, below)
    }

    private func placeTip(in entry: (screen: NSScreen, panel: NSPanel, shade: OnboardingShadeView), spot: CGRect, animated: Bool) {
        tipState.index = index
        tipState.step = step
        let host: FirstMouseHostingView<OnboardingTipView>
        if let existing = tipHost { host = existing } else {
            host = FirstMouseHostingView(rootView: OnboardingTipView(state: tipState, next: { [weak self] in self?.next() }, skip: { [weak self] in self?.finish() }))
            host.appearance = NSAppearance(named: .darkAqua)
            tipHost = host
        }
        if host.superview !== entry.shade { host.removeFromSuperview(); entry.shade.addSubview(host) }
        host.isHidden = false
        let size = host.fittingSize
        let placement = Self.tipFrame(spot: spot, size: size, visible: entry.screen.visibleFrame)
        tipState.arrowX = placement.arrowX
        tipState.arrowBelow = !placement.below
        let local = placement.frame.offsetBy(dx: -entry.screen.frame.minX, dy: -entry.screen.frame.minY)
        if animated, host.frame.width > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.42
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                host.animator().frame = local
            }
        } else {
            host.frame = local
        }
    }
}

/// 无边框面板默认不能成为键窗口；引导层要接键盘，必须能。
final class OnboardingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 提示卡宿主：面板不是键窗口、本应用不在前台时，第一下点击也直接落到按钮上，不用先点一下激活。
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - 压暗与聚光灯

/// 单个显示器上的引导遮罩：整屏压暗 55%，聚光灯挖空当前目标，边缘一圈冷白描边加向外扩散的脉冲。
/// 挖空处点击前进；其余区域吃掉点击。坐标为 AppKit 屏幕本地坐标（左下角原点）。
final class OnboardingShadeView: NSView {
    var onSpotlightClick: (() -> Void)?
    /// 点在聚光灯与提示卡之外：结束引导。
    var onOutsideClick: (() -> Void)?
    /// 键盘：返回是否已处理。
    var onKey: ((UInt16, Bool) -> Bool)?
    private let dimLayer = CAShapeLayer(), ringLayer = CAShapeLayer(), pulseLayer = CAShapeLayer()
    private var hole: CGRect?
    private var radius: CGFloat = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.55).cgColor
        ringLayer.fillColor = nil; ringLayer.lineWidth = 1.5
        pulseLayer.fillColor = nil; pulseLayer.lineWidth = 1.5
        for shape in [dimLayer, ringLayer, pulseLayer] { shape.contentsScale = 2; layer?.addSublayer(shape) }
        applyColors()
    }
    required init?(coder: NSCoder) { nil }

    private func applyColors() {
        ringLayer.strokeColor = CaploNSColor.accent.withAlphaComponent(0.9).cgColor
        pulseLayer.strokeColor = CaploNSColor.accent.cgColor
    }

    override func layout() {
        super.layout()
        for shape in [dimLayer, ringLayer, pulseLayer] { shape.frame = bounds; shape.contentsScale = window?.backingScaleFactor ?? 2 }
        set(hole: hole, radius: radius, animated: false)
    }

    /// `hole` 为 nil 表示这块显示器整屏压暗、没有聚光灯。
    func set(hole: CGRect?, radius: CGFloat, animated: Bool) {
        self.hole = hole; self.radius = radius
        let dim = CGMutablePath()
        dim.addRect(bounds)
        if let hole { dim.addPath(CGPath(roundedRect: hole, cornerWidth: radius, cornerHeight: radius, transform: nil)) }
        let ring = hole.map { CGPath(roundedRect: $0.insetBy(dx: -3, dy: -3), cornerWidth: radius + 3, cornerHeight: radius + 3, transform: nil) }
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.42)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        dimLayer.path = dim
        ringLayer.path = ring
        ringLayer.isHidden = hole == nil
        CATransaction.commit()
        restartPulse(ring: ring, hole: hole)
    }

    /// 脉冲：从描边处向外扩 8 点并淡出，1.8 秒一轮；减弱动态效果时不放。
    private func restartPulse(ring: CGPath?, hole: CGRect?) {
        pulseLayer.removeAllAnimations()
        guard let ring, let hole, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { pulseLayer.isHidden = true; return }
        pulseLayer.isHidden = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pulseLayer.path = ring
        CATransaction.commit()
        let expanded = CGPath(roundedRect: hole.insetBy(dx: -11, dy: -11), cornerWidth: radius + 11, cornerHeight: radius + 11, transform: nil)
        let path = CABasicAnimation(keyPath: "path"); path.fromValue = ring; path.toValue = expanded
        let opacity = CABasicAnimation(keyPath: "opacity"); opacity.fromValue = 0.7; opacity.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [path, opacity]
        group.duration = 1.8
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        pulseLayer.add(group, forKey: "pulse")
    }

    override func mouseDown(with event: NSEvent) {
        // 点到遮罩就把本应用带到前台并拿到键盘，之后 Esc 一定能退出引导。
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey(); window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let hole, hole.contains(point) { onSpotlightClick?() } else { onOutsideClick?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event.keyCode, event.modifierFlags.contains(.command)) != true { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { _ = onKey?(53, false) }
}

// MARK: - 提示卡

@MainActor @Observable
final class OnboardingTipState {
    var index = 0
    var count = 1
    var step = OnboardingTour.steps[0]
    var arrowX: CGFloat = 150
    /// 箭头在卡片下沿（卡片在聚光灯上方）；否则在上沿。
    var arrowBelow = true
}

/// 玻璃提示卡：标题、说明、进度点、跳过 / 下一步；内容切换时淡入上浮。
struct OnboardingTipView: View {
    let state: OnboardingTipState
    let next: () -> Void
    let skip: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.step.title).font(CaploFont.panelTitle).foregroundStyle(CaploColor.textPrimary)
            Text(state.step.body).font(CaploFont.body).foregroundStyle(CaploColor.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: CaploMetrics.Spacing.s) {
                HStack(spacing: 5) {
                    ForEach(0..<state.count, id: \.self) { i in
                        Capsule().fill(i == state.index ? CaploColor.accent : CaploColor.textPrimary.opacity(0.22))
                            .frame(width: i == state.index ? 14 : 5, height: 5)
                    }
                }
                .accessibilityLabel("第 \(state.index + 1) 步，共 \(state.count) 步")
                Spacer(minLength: 0)
                if !state.step.last {
                    Button("跳过", action: skip).buttonStyle(StudioButtonStyle(.quiet, size: .small))
                }
                Button(state.step.last ? "开始录制" : state.index == 0 ? "看看怎么用" : "下一步", action: next)
                    .buttonStyle(StudioButtonStyle(.primary, size: .small))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, CaploMetrics.Spacing.s)
        }
        .id(state.index)
        .transition(.opacity.combined(with: .offset(y: 6)))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.26), value: state.index)
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
        .frame(width: Self.width, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: CaploMetrics.Radius.floating, style: .continuous)
                .fill(CaploColor.glassShade)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                .overlay { CaploMaterialBackground(.floating).clipShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.floating, style: .continuous)) }
                .overlay { CaploGlassBorder(cornerRadius: CaploMetrics.Radius.floating) }
        }
        .overlay(alignment: state.arrowBelow ? .bottomLeading : .topLeading) {
            // 箭头：14 点的旋转方块，露出卡片外 7 点，指向目标中心。
            RoundedRectangle(cornerRadius: 2).fill(CaploColor.surfaceOpaqueWindow.opacity(0.96))
                .frame(width: 14, height: 14).rotationEffect(.degrees(45))
                .offset(x: state.arrowX - 7, y: state.arrowBelow ? 7 : -7)
                .allowsHitTesting(false)
        }
        .padding(.vertical, 7)
        .foregroundStyle(CaploColor.textPrimary)
        .tint(CaploColor.accent)
        .preferredColorScheme(.dark)
    }
}

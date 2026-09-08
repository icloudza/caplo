import AppKit
import CaptureKit
import CaploDesignSystem

/// 窗口模式的准备阶段：每个显示器盖一层压暗遮罩，只把选中的窗口挖空并沿边缘包一层虚线，
/// 60 Hz 跟随窗口移动 / 缩放，窗口不在屏幕上（最小化、关闭、其他空间）时整层隐藏。
/// 遮罩完全穿透点击，用户可以继续操作目标窗口；切换到别的应用时，把录制目标换成该应用最前面的
/// 窗口（同一应用内换窗口不改目标）。按 REC、返回录制方式或重新点选时撤掉。
@MainActor
final class WindowHighlightSession {
    private(set) static var current: WindowHighlightSession?

    /// 为录制条模型开始跟随；同一模型重复调用不重建。
    static func begin(model: RecordBarModel) {
        if let current, current.model === model { current.tick(); return }
        dismiss()
        current = WindowHighlightSession(model: model)
    }

    static func dismiss() {
        current?.tearDown()
        current = nil
    }

    private weak var model: RecordBarModel?
    private var panels: [(screen: NSScreen, panel: NSPanel, shade: WindowShadeView)] = []
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    /// 用户刚切换到的应用：等它的窗口升到最前后再采用，最多等一秒。
    private var pendingPID: pid_t?
    private var pendingTicks = 0
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    /// 最近一次跟随到的窗口位置（全局左上角原点坐标）；窗口不在屏幕上时为 nil。供测试与调试。
    private(set) var trackedBounds: CGRect?
    var isShowing: Bool { panels.contains { $0.panel.isVisible } }

    private init(model: RecordBarModel) {
        self.model = model
        rebuildPanels()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.applicationActivated(pid) }
        }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // 加入 common 模式：拖动录制条期间的事件跟踪循环里也继续跟随。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tearDown() {
        timer?.invalidate(); timer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        for entry in panels { entry.panel.orderOut(nil); entry.panel.contentView = nil }
        panels.removeAll()
    }

    /// 每个显示器一层：置顶层级（菜单栏与程序坞之上）、录制条之下；完全穿透，不参与点击与键盘。
    private func rebuildPanels() {
        for entry in panels { entry.panel.orderOut(nil); entry.panel.contentView = nil }
        panels = NSScreen.screens.map { screen in
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
            panel.sharingType = .none
            let shade = WindowShadeView(frame: CGRect(origin: .zero, size: screen.frame.size))
            panel.contentView = shade
            return (screen, panel, shade)
        }
    }

    private func applicationActivated(_ pid: pid_t?) {
        guard let pid, pid != ownPID, pid != model?.source?.processID else { pendingPID = nil; return }
        pendingPID = pid
        pendingTicks = 0
    }

    private func tick() {
        guard let model, model.mode == .window, let source = model.source, let windowID = source.windowID else { hide(); return }
        if let pendingPID { resolvePending(pendingPID, currentWindowID: windowID) }
        guard let bounds = WindowGeometry.onScreenBounds(of: windowID) else { hide(); return }
        trackedBounds = bounds
        if panels.map(\.screen.frame) != NSScreen.screens.map(\.frame) { rebuildPanels() }
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? bounds.maxY
        let windowRect = WindowGeometry.appKitRect(fromGlobal: bounds, primaryHeight: primaryHeight)
        let scale = (NSScreen.screens.first { $0.frame.intersects(windowRect) } ?? NSScreen.main)?.backingScaleFactor ?? 2
        let pixelSize = "\(Int(bounds.width * scale)) × \(Int(bounds.height * scale))"
        for entry in panels {
            let hole = WindowGeometry.localRect(bounds, in: entry.screen.frame, primaryHeight: primaryHeight)
            entry.shade.update(hole: hole, name: source.applicationName ?? "窗口", pixelSize: pixelSize)
            if !entry.panel.isVisible { entry.panel.orderFrontRegardless() }
        }
    }

    private func resolvePending(_ pid: pid_t, currentWindowID: UInt32) {
        pendingTicks += 1
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        if let front = WindowGeometry.frontmostWindow(in: list, excluding: ownPID), front.pid == pid {
            pendingPID = nil
            if front.windowID != currentWindowID, let model {
                Task { await model.adoptFrontmost(windowID: front.windowID) }
            }
        } else if pendingTicks > 60 {
            pendingPID = nil
        }
    }

    private func hide() {
        trackedBounds = nil
        for entry in panels where entry.panel.isVisible { entry.panel.orderOut(nil) }
    }
}

/// 窗口几何换算与最前窗口判定；纯函数便于测试。
enum WindowGeometry {
    /// 窗口当前在屏幕上的位置（全局左上角原点坐标）；不在屏幕上返回 nil。
    /// 只用 `optionIncludingWindow` 单窗口查询：`CGWindowListCreateDescriptionFromArray` 在 macOS 27 beta 上恒返回空。
    static func onScreenBounds(of windowID: UInt32) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
              (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
              let raw = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary), bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }

    /// 全局左上角原点坐标换算到 AppKit 屏幕坐标（主显示器左下角原点）。
    static func appKitRect(fromGlobal rect: CGRect, primaryHeight: CGFloat? = nil) -> CGRect {
        let height = primaryHeight ?? NSScreen.screens.first?.frame.maxY ?? rect.maxY
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 全局左上角原点坐标换算到某个显示器覆盖层的本地翻转坐标（该显示器左上角为原点）。
    static func localRect(_ global: CGRect, in screenFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: global.minX - screenFrame.minX, y: global.minY - (primaryHeight - screenFrame.maxY),
               width: global.width, height: global.height)
    }

    struct FrontWindow: Equatable {
        let pid: pid_t
        let windowID: UInt32
        let bounds: CGRect
    }

    /// 屏幕上最前面的普通窗口（层 0、可见、不小于 32 点），跳过指定进程。列表须按前后顺序排列。
    static func frontmostWindow(in list: [[String: Any]], excluding pid: pid_t) -> FrontWindow? {
        for info in list {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue, owner != Int(pid),
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary), bounds.width >= 32, bounds.height >= 32 else { continue }
            return FrontWindow(pid: pid_t(owner), windowID: number, bounds: bounds)
        }
        return nil
    }
}

/// 单个显示器上的遮罩：压暗全屏、挖空目标窗口、沿窗口边缘画虚线，左上方标签显示应用名与像素尺寸。
/// 翻转坐标（左上角原点），与 `WindowGeometry.localRect` 一致。
private final class WindowShadeView: NSView {
    private var hole = CGRect.zero
    private var name = ""
    private var pixelSize = ""
    override var isFlipped: Bool { true }

    func update(hole: CGRect, name: String, pixelSize: String) {
        guard hole != self.hole || name != self.name || pixelSize != self.pixelSize else { return }
        self.hole = hole; self.name = name; self.pixelSize = pixelSize
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let visibleHole = hole.intersection(bounds)
        let shade = NSBezierPath(rect: bounds)
        if !visibleHole.isEmpty { shade.append(NSBezierPath(rect: visibleHole)); shade.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.32).setFill()
        shade.fill()
        guard !visibleHole.isEmpty else { return }

        // 虚线贴着窗口边缘画在外侧的压暗区域上，不遮住窗口内容。
        let border = NSBezierPath(rect: hole.insetBy(dx: -1, dy: -1))
        border.lineWidth = 2
        border.setLineDash([9, 5], count: 2, phase: 0)
        CaploNSColor.accent.setStroke(); border.stroke()

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let mode = "窗口 · \(name)"
        let modeWidth = (mode as NSString).size(withAttributes: attributes).width + 20
        let sizeWidth = (pixelSize as NSString).size(withAttributes: attributes).width + 20
        // 顶到屏幕上沿（菜单栏之下）放不下时画进窗口内部。
        var y = hole.minY - 34
        if y < 8 { y = hole.minY + 8 }
        let modeRect = CGRect(x: max(8, hole.minX), y: y, width: modeWidth, height: 26)
        let sizeRect = CGRect(x: modeRect.maxX + 6, y: y, width: sizeWidth, height: 26)
        for (badge, text, fill) in [(modeRect, mode, CaploNSColor.accent), (sizeRect, pixelSize, NSColor.black.withAlphaComponent(0.75))] {
            fill.setFill(); NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7).fill()
            (text as NSString).draw(at: CGPoint(x: badge.minX + 10, y: badge.minY + 5), withAttributes: attributes)
        }
    }
}

import AppKit
import CaptureKit
import CaploDesignSystem

/// 屏幕上直接选窗口：每个显示器覆盖一层透明面板，鼠标悬停处的窗口用虚线高亮并显示应用名与尺寸，
/// 单击选定，Esc 取消。窗口列表与几何来自 ScreenCaptureKit，前后顺序按系统窗口层级。
@MainActor
enum WindowPicker {
    static func pick(from sources: [CaptureSource]) async -> CaptureSource? {
        let windows = ordered(sources.filter { $0.kind == .window && $0.frame != nil })
        guard !windows.isEmpty else { return nil }
        current?.cancel()
        return await withCheckedContinuation { continuation in
            // 会话必须被强引用到结束：面板由 AppKit 持有，但点击 / Esc 的回调都经由会话转发。
            let session = Session(windows: windows) { picked in
                current = nil
                continuation.resume(returning: picked)
            }
            current = session
            session.begin()
        }
    }

    private static var current: Session?

    /// 外部撤销（例如准备开始录制或退出）：按取消处理。
    static func cancel() { current?.cancel() }

    /// 按当前屏幕层级从前到后排序，悬停命中时取最前面的窗口。
    private static func ordered(_ windows: [CaptureSource]) -> [CaptureSource] {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var order: [UInt32: Int] = [:]
        for (index, info) in list.enumerated() {
            if let number = info[kCGWindowNumber as String] as? UInt32 { order[number] = index }
        }
        return windows.sorted { (order[$0.windowID ?? 0] ?? .max) < (order[$1.windowID ?? 0] ?? .max) }
    }

    @MainActor
    private final class Session {
        let windows: [CaptureSource]
        private var panels: [NSPanel] = []
        private var monitor: Any?
        private var completion: ((CaptureSource?) -> Void)?

        init(windows: [CaptureSource], completion: @escaping (CaptureSource?) -> Void) {
            self.windows = windows; self.completion = completion
        }

        func cancel() { finish(nil) }

        func begin() {
            for screen in NSScreen.screens {
                let panel = PickerPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                panel.level = StudioLevel.overlay
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.ignoresMouseEvents = false
                panel.acceptsMouseMovedEvents = true
                panel.hidesOnDeactivate = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let overlay = WindowPickerOverlay(screen: screen, windows: windows, frame: CGRect(origin: .zero, size: screen.frame.size))
                overlay.picked = { [weak self] source in self?.finish(source) }
                panel.contentView = overlay
                panel.orderFrontRegardless()
                panels.append(panel)
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            // 鼠标所在屏幕的面板成为 key 并把覆盖层设为第一响应者，Esc 才能到达。
            let keyPanel = panels.first { $0.frame.contains(NSEvent.mouseLocation) } ?? panels.first
            keyPanel?.makeKeyAndOrderFront(nil)
            keyPanel?.makeFirstResponder(keyPanel?.contentView)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { self?.finish(nil); return nil }
                return event
            }
            for panel in panels { (panel.contentView as? WindowPickerOverlay)?.refreshHover() }
        }

        private func finish(_ source: CaptureSource?) {
            guard let completion else { return }
            self.completion = nil
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            for panel in panels { panel.orderOut(nil); panel.contentView = nil }
            panels.removeAll()
            completion(source)
        }
    }

    private final class PickerPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}

/// 单个显示器上的选择层。坐标：来源几何为全局左上角原点，视图翻转后与其一致，只需减去本屏幕偏移。
@MainActor
private final class WindowPickerOverlay: NSView {
    var picked: ((CaptureSource?) -> Void)?
    private let screen: NSScreen
    private let windows: [CaptureSource]
    private var hovered: CaptureSource?
    private let iconCache = NSCache<NSNumber, NSImage>()
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(screen: NSScreen, windows: [CaptureSource], frame: CGRect) {
        self.screen = screen; self.windows = windows
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("不支持归档初始化") }

    /// 本屏幕在全局左上角坐标系中的原点。
    private var globalOrigin: CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        return CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
    }
    private func localRect(_ global: CGRect) -> CGRect {
        CGRect(x: global.minX - globalOrigin.x, y: global.minY - globalOrigin.y, width: global.width, height: global.height)
    }

    func refreshHover() {
        let mouse = NSEvent.mouseLocation
        guard screen.frame.contains(mouse) else { if hovered != nil { hovered = nil; needsDisplay = true }; return }
        let point = CGPoint(x: mouse.x, y: (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY) - mouse.y)
        let next = windows.first { $0.frame?.contains(point) == true }
        if next?.id != hovered?.id { hovered = next; needsDisplay = true }
    }

    override func mouseMoved(with event: NSEvent) { refreshHover() }
    override func mouseDown(with event: NSEvent) { refreshHover(); if let hovered { picked?(hovered) } }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { picked?(nil) } else { super.keyDown(with: event) } }

    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        let target = hovered?.frame.map(localRect)
        if let target { shade.append(NSBezierPath(rect: target)); shade.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.28).setFill(); shade.fill()
        // 高亮窗口区域同样不能是全透明，否则单击会穿透到该窗口而不是选定它。
        if let target { NSColor.black.withAlphaComponent(0.01).setFill(); target.fill() }

        if let target, let hovered {
            let outline = NSBezierPath(rect: target.insetBy(dx: 1.5, dy: 1.5))
            outline.lineWidth = 3
            outline.setLineDash([10, 6], count: 2, phase: 0)
            CaploNSColor.accent.setStroke(); outline.stroke()
            drawDescription(for: hovered, in: target)
        }
        drawHint()
    }

    private func drawDescription(for source: CaptureSource, in rect: CGRect) {
        let name = source.applicationName ?? String(localized: "应用")
        let title = source.windowTitle ?? ""
        let size = "\(Int(rect.width)) × \(Int(rect.height))"
        let nameAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white]
        let detailAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white.withAlphaComponent(0.8)]
        let nameSize = (name as NSString).size(withAttributes: nameAttributes)
        let titleSize = (title as NSString).size(withAttributes: detailAttributes)
        let sizeSize = (size as NSString).size(withAttributes: detailAttributes)
        let iconSide = 48.0
        let width = min(rect.width - 24, max(220, max(nameSize.width, titleSize.width, sizeSize.width) + 40))
        let height = iconSide + 16 + nameSize.height + 6 + titleSize.height + 4 + sizeSize.height + 20
        let card = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14).fill()
        if let icon = icon(for: source) {
            icon.draw(in: CGRect(x: card.midX - iconSide / 2, y: card.minY + 12, width: iconSide, height: iconSide), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        var y = card.minY + 12 + iconSide + 4
        (name as NSString).draw(in: CGRect(x: card.minX + 12, y: y, width: card.width - 24, height: nameSize.height + 2), withAttributes: centered(nameAttributes))
        y += nameSize.height + 6
        (title as NSString).draw(in: CGRect(x: card.minX + 12, y: y, width: card.width - 24, height: titleSize.height + 2), withAttributes: centered(detailAttributes, truncate: true))
        y += titleSize.height + 4
        (size as NSString).draw(in: CGRect(x: card.minX + 12, y: y, width: card.width - 24, height: sizeSize.height + 2), withAttributes: centered(detailAttributes))
    }

    private func centered(_ attributes: [NSAttributedString.Key: Any], truncate: Bool = false) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        if truncate { paragraph.lineBreakMode = .byTruncatingMiddle }
        var result = attributes; result[.paragraphStyle] = paragraph
        return result
    }

    private func icon(for source: CaptureSource) -> NSImage? {
        guard let pid = source.processID else { return nil }
        if let cached = iconCache.object(forKey: NSNumber(value: pid)) { return cached }
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        iconCache.setObject(icon, forKey: NSNumber(value: pid))
        return icon
    }

    private func drawHint() {
        let name = hovered?.applicationName ?? ""
        let text = hovered == nil ? String(localized: "将鼠标移到要录制的窗口上，单击即可选定 · Esc 取消") : String(localized: "单击选定“\(name)”窗口 · Esc 取消")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let pill = CGRect(x: bounds.midX - size.width / 2 - 18, y: 44, width: size.width + 36, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: pill.minX + 18, y: pill.minY + 8), withAttributes: attributes)
    }
}

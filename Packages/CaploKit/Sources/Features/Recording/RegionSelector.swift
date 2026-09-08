import AppKit
import ScreenCaptureKit
import CaptureKit
import CaploDesignSystem

/// 区域框选会话：在鼠标所在显示器上拖出虚线框，松手后框与手柄留在屏幕上，可继续移动 / 调整，
/// 录制条同时出现；按 REC 或取消时才撤掉覆盖层。拖动过程中光标旁显示像素级放大镜。
@MainActor
final class RegionSession {
    struct Selection: Sendable {
        let displayID: CGDirectDisplayID
        /// ScreenCaptureKit 使用的显示器本地坐标，左上角原点，单位为点。
        let rect: CGRect
    }

    private(set) static var current: RegionSession?

    private let screen: NSScreen
    let displayID: CGDirectDisplayID
    private let panel: RegionPanel
    private let overlay: RegionOverlay
    private let onCommit: (Selection) -> Void
    private let onChange: (Selection) -> Void
    private let onCancel: () -> Void
    private var committed = false

    /// 在鼠标所在显示器开始框选；已有会话则先撤掉。
    static func begin(onCommit: @escaping (Selection) -> Void, onChange: @escaping (Selection) -> Void, onCancel: @escaping () -> Void) {
        dismiss()
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
              let displayID = displayID(of: screen) else { onCancel(); return }
        current = RegionSession(screen: screen, displayID: displayID, onCommit: onCommit, onChange: onChange, onCancel: onCancel)
        current?.show()
    }

    /// 清空当前框，让用户重新拖一次；没有会话时开始新会话。
    static func reset(onCommit: @escaping (Selection) -> Void, onChange: @escaping (Selection) -> Void, onCancel: @escaping () -> Void) {
        if let current { current.overlay.clear() } else { begin(onCommit: onCommit, onChange: onChange, onCancel: onCancel) }
    }

    static func dismiss() {
        current?.tearDown()
        current = nil
    }

    /// 倒计时与录制期间的外观：只保留区域虚线，撤掉遮罩、手柄、标签与提示，并让覆盖层穿透点击；
    /// 本应用窗口不进入录制画面，所以虚线不会被录进去。回到录制条时恢复可编辑外观。
    func setRecordingLook(_ recording: Bool) {
        overlay.recordingLook = recording
        panel.ignoresMouseEvents = recording
        if !recording { panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(overlay) }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private init(screen: NSScreen, displayID: CGDirectDisplayID, onCommit: @escaping (Selection) -> Void, onChange: @escaping (Selection) -> Void, onCancel: @escaping () -> Void) {
        self.screen = screen; self.displayID = displayID
        self.onCommit = onCommit; self.onChange = onChange; self.onCancel = onCancel
        panel = RegionPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        // 置顶层级（菜单栏与程序坞之上）、录制条之下，录制条仍可点击。
        panel.level = StudioLevel.overlay
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        // 失活时不隐藏：点击录制条或其他窗口后覆盖层仍在。
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 不可共享：区域录制时的虚线框与放大镜都不进片子。
        panel.sharingType = .none
        overlay = RegionOverlay(frame: CGRect(origin: .zero, size: screen.frame.size), scale: screen.backingScaleFactor)
        panel.contentView = overlay
    }

    private func show() {
        overlay.changed = { [weak self] rect in
            guard let self else { return }
            let selection = Selection(displayID: displayID, rect: rect)
            if committed { onChange(selection) }
        }
        overlay.completed = { [weak self] rect in
            guard let self else { return }
            let selection = Selection(displayID: displayID, rect: rect)
            if committed { onChange(selection) } else { committed = true; onCommit(selection) }
        }
        overlay.cancelled = { [weak self] in
            guard let self else { return }
            Self.dismiss()
            onCancel()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(overlay)
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task { await captureScreenshot() }
    }

    /// 一次性截取本显示器画面作为放大镜像素源；排除本应用窗口，不显示光标。
    private func captureScreenshot() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
            let filter = OwnWindowExclusion(content: content).filter(display: display)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(Double(display.width) * screen.backingScaleFactor)
            configuration.height = Int(Double(display.height) * screen.backingScaleFactor)
            configuration.showsCursor = false
            configuration.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            overlay.screenshot = image
        } catch {
            // 没有截图时放大镜不显示，框选本身不受影响。
        }
    }

    private func tearDown() {
        overlay.changed = nil; overlay.completed = nil; overlay.cancelled = nil
        panel.orderOut(nil)
        panel.contentView = nil
    }
}

private final class RegionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 覆盖层视图：翻转坐标（左上角原点）与 ScreenCaptureKit 的区域坐标一致。
private final class RegionOverlay: NSView {
    var changed: ((CGRect) -> Void)?
    var completed: ((CGRect) -> Void)?
    var cancelled: (() -> Void)?
    var screenshot: CGImage? { didSet { needsDisplay = true } }
    /// 录制中外观：只画虚线。
    var recordingLook = false { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }

    private enum Drag { case draw, move, resize(Handle) }
    private enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }
    private let scale: CGFloat
    private var drag: Drag?
    private var origin = CGPoint.zero
    private var initial = CGRect.zero
    private var selection = CGRect.zero
    private var cursor = CGPoint.zero
    private var tracking = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: CGRect, scale: CGFloat) {
        self.scale = scale
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("不支持归档初始化") }

    func clear() { selection = .zero; drag = nil; needsDisplay = true; window?.makeKeyAndOrderFront(nil) }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        if recordingLook {
            guard !selection.isEmpty else { return }
            // 虚线画在选区外侧，不遮住被录制的画面。
            let border = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            border.setLineDash([9, 5], count: 2, phase: 0)
            CaploNSColor.accent.setStroke(); border.stroke()
            return
        }
        let shade = NSBezierPath(rect: bounds)
        if !selection.isEmpty { shade.append(NSBezierPath(rect: selection)); shade.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.32).setFill()
        shade.fill()
        if !selection.isEmpty {
            // 无边框透明窗口在 alpha 为 0 的像素上会让点击穿透到下层应用；
            // 选区内部铺一层肉眼不可见的填充，保证移动 / 调整的点击留在覆盖层。
            NSColor.black.withAlphaComponent(0.01).setFill(); selection.fill()
            let border = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            border.setLineDash([9, 5], count: 2, phase: 0)
            CaploNSColor.accent.setStroke(); border.stroke()
            if drag == nil || isResizeDrag {
                for point in handlePoints.values {
                    let dot = NSBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
                    NSColor.white.setFill(); dot.fill()
                    CaploNSColor.accent.setStroke(); dot.lineWidth = 1.5; dot.stroke()
                }
            }
            drawBadges()
        }
        if drag != nil { drawLoupe() }
        drawHint()
    }

    private var isResizeDrag: Bool { if case .resize = drag { return true } else { return false } }

    private var handlePoints: [Handle: CGPoint] {
        [.topLeft: CGPoint(x: selection.minX, y: selection.minY), .top: CGPoint(x: selection.midX, y: selection.minY),
         .topRight: CGPoint(x: selection.maxX, y: selection.minY), .right: CGPoint(x: selection.maxX, y: selection.midY),
         .bottomRight: CGPoint(x: selection.maxX, y: selection.maxY), .bottom: CGPoint(x: selection.midX, y: selection.maxY),
         .bottomLeft: CGPoint(x: selection.minX, y: selection.maxY), .left: CGPoint(x: selection.minX, y: selection.midY)]
    }

    /// 选区上方：模式标签与像素尺寸。
    private func drawBadges() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = "\(Int(selection.width * scale)) × \(Int(selection.height * scale))"
        let mode = "自定义区域"
        let sizeWidth = (size as NSString).size(withAttributes: attributes).width + 20
        let modeWidth = (mode as NSString).size(withAttributes: attributes).width + 20
        var y = selection.minY - 34
        if y < 8 { y = selection.minY + 8 }
        let modeRect = CGRect(x: selection.minX, y: y, width: modeWidth, height: 26)
        let sizeRect = CGRect(x: modeRect.maxX + 6, y: y, width: sizeWidth, height: 26)
        for (rect, text, fill) in [(modeRect, mode, CaploNSColor.accent), (sizeRect, size, NSColor.black.withAlphaComponent(0.75))] {
            fill.setFill(); NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            (text as NSString).draw(at: CGPoint(x: rect.minX + 10, y: rect.minY + 5), withAttributes: attributes)
        }
    }

    /// 像素级放大镜：以一次性截图为源，围绕光标取 24×24 点放大 6 倍，带网格线与十字线。
    private func drawLoupe() {
        guard let screenshot else { return }
        let side = 150.0, radius = 12.0
        let sampleSide = 24.0
        var frame = CGRect(x: cursor.x + 24, y: cursor.y + 24, width: side, height: side)
        if frame.maxX > bounds.maxX - 8 { frame.origin.x = cursor.x - 24 - side }
        if frame.maxY > bounds.maxY - 8 { frame.origin.y = cursor.y - 24 - side }
        let sample = CGRect(x: (cursor.x - sampleSide / 2) * scale, y: (cursor.y - sampleSide / 2) * scale, width: sampleSide * scale, height: sampleSide * scale)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).addClip()
        NSColor.black.setFill(); frame.fill()
        if let cropped = screenshot.cropping(to: sample.integral) {
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: cropped, size: .zero).draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        // 像素网格与十字线
        let step = side / sampleSide
        NSColor.white.withAlphaComponent(0.12).setStroke()
        for index in 1..<Int(sampleSide) {
            let offset = Double(index) * step
            NSBezierPath.strokeLine(from: CGPoint(x: frame.minX + offset, y: frame.minY), to: CGPoint(x: frame.minX + offset, y: frame.maxY))
            NSBezierPath.strokeLine(from: CGPoint(x: frame.minX, y: frame.minY + offset), to: CGPoint(x: frame.maxX, y: frame.minY + offset))
        }
        CaploNSColor.accent.setStroke()
        let cross = NSBezierPath(); cross.lineWidth = 1.5
        cross.move(to: CGPoint(x: frame.midX, y: frame.minY)); cross.line(to: CGPoint(x: frame.midX, y: frame.maxY))
        cross.move(to: CGPoint(x: frame.minX, y: frame.midY)); cross.line(to: CGPoint(x: frame.maxX, y: frame.midY))
        cross.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let border = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        border.lineWidth = 2; NSColor.white.withAlphaComponent(0.9).setStroke(); border.stroke()
        let label = "\(Int(cursor.x * scale)), \(Int(cursor.y * scale))"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let labelSize = (label as NSString).size(withAttributes: attributes)
        let tag = CGRect(x: frame.midX - labelSize.width / 2 - 8, y: frame.maxY + 6, width: labelSize.width + 16, height: labelSize.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill(); NSBezierPath(roundedRect: tag, xRadius: 5, yRadius: 5).fill()
        (label as NSString).draw(at: CGPoint(x: tag.minX + 8, y: tag.minY + 3), withAttributes: attributes)
    }

    private func drawHint() {
        let hint: String
        if drag != nil { hint = "松开鼠标完成 · 单击生成最小 32 × 32 框" }
        else if selection.isEmpty { hint = "拖动框选要录制的区域 · Esc 取消" }
        else { hint = "拖动内部移动、拖动手柄调整，在底部录制条按 REC 开始 · Esc 取消" }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
        let hintSize = (hint as NSString).size(withAttributes: attributes)
        let pill = CGRect(x: bounds.midX - hintSize.width / 2 - 18, y: 44, width: hintSize.width + 36, height: hintSize.height + 16)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        (hint as NSString).draw(at: CGPoint(x: pill.minX + 18, y: pill.minY + 8), withAttributes: attributes)
    }

    // MARK: 鼠标与键盘

    override func resetCursorRects() {
        guard !recordingLook else { return }
        addCursorRect(bounds, cursor: .crosshair)
        guard !selection.isEmpty else { return }
        addCursorRect(selection, cursor: .openHand)
        for (handle, point) in handlePoints {
            let rect = CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
            switch handle {
            case .top, .bottom: addCursorRect(rect, cursor: .resizeUpDown)
            case .left, .right: addCursorRect(rect, cursor: .resizeLeftRight)
            default: addCursorRect(rect, cursor: .crosshair)
            }
        }
    }

    override func mouseMoved(with event: NSEvent) { cursor = convert(event.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor = point; origin = point; initial = selection
        if !selection.isEmpty, let handle = handlePoints.first(where: { hypot($0.value.x - point.x, $0.value.y - point.y) <= 10 })?.key {
            drag = .resize(handle)
        } else if selection.contains(point) {
            drag = .move
        } else {
            drag = .draw; selection = .zero
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor = point
        switch drag {
        case .draw:
            selection = CaptureRegion.clampedDrag(from: origin, to: point, in: bounds)
        case .move:
            selection.origin = CGPoint(x: min(bounds.maxX - initial.width, max(bounds.minX, initial.minX + point.x - origin.x)),
                                       y: min(bounds.maxY - initial.height, max(bounds.minY, initial.minY + point.y - origin.y)))
            changed?(selection)
        case .resize(let handle):
            selection = resized(initial, handle: handle, to: point)
            changed?(selection)
        case nil: break
        }
        needsDisplay = true
    }

    /// 松手：新框至少 32×32 才生效，否则视为误触并等待重新拖动；移动 / 调整结束时通知一次。
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        let finished = drag
        drag = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        switch finished {
        case .draw:
            // 没拖出足够大小（含单击空白）：以按下点为锚生成 32×32 的最小框，而不是清空。
            if selection.width < 32 || selection.height < 32 {
                let point = convert(event.locationInWindow, from: nil)
                let x = min(origin.x, point.x), y = min(origin.y, point.y)
                selection = CGRect(x: min(max(bounds.minX, x), bounds.maxX - 32), y: min(max(bounds.minY, y), bounds.maxY - 32),
                                   width: max(32, selection.width), height: max(32, selection.height)).intersection(bounds)
            }
            completed?(selection)
        case .move, .resize: completed?(selection)
        case nil: break
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelled?() } else { super.keyDown(with: event) }
    }

    private func resized(_ rect: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        let x = min(bounds.maxX, max(bounds.minX, point.x)), y = min(bounds.maxY, max(bounds.minY, point.y))
        switch handle {
        case .topLeft: minX = x; minY = y
        case .top: minY = y
        case .topRight: maxX = x; minY = y
        case .right: maxX = x
        case .bottomRight: maxX = x; maxY = y
        case .bottom: maxY = y
        case .bottomLeft: minX = x; maxY = y
        case .left: minX = x
        }
        // 最小 32×32，越过对边时以对边为锚。
        if maxX - minX < 32 { if [.left, .topLeft, .bottomLeft].contains(handle) { minX = maxX - 32 } else { maxX = minX + 32 } }
        if maxY - minY < 32 { if [.top, .topLeft, .topRight].contains(handle) { minY = maxY - 32 } else { maxY = minY + 32 } }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(bounds)
    }
}

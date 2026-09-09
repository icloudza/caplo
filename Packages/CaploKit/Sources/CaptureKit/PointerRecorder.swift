import AppKit
import CoreMedia
import EditingCore

/// 只在录制期间读取鼠标位置和点击，不监听键盘或文本；自身控制窗口的点击不进入素材。
/// AppKit 全局鼠标监听不要求键盘监听权限；监听不可用时保留基础录制和手动聚焦能力。
@MainActor
final class PointerRecorder {
    private var monitor: Any?
    private var timer: Timer?
    private var bounds: CGRect
    private let windowID: CGWindowID?
    private let clock: CMClock
    private let writer: SegmentedCaptureWriter
    private var ticks = 0
    private var lastDragTime = 0.0
    private var lastScrollTime = 0.0
    private var pendingScroll = CGPoint.zero
    private var wasInside = false
    private var lastPosition = CGPoint.zero
    private var shape: PointerShape = .arrow
    private var captured: CapturedCursor?
    private var lastCursorImage: Data?
    private var lastHotspot = CGPoint.zero
    // 同步识别常用形态，并保存真实光标位图；不读取屏幕图像。
    private lazy var knownCursors: [(PointerShape, Data?)] = [
        (PointerShape.arrow, NSCursor.arrow), (PointerShape.pointer, NSCursor.pointingHand), (PointerShape.text, NSCursor.iBeam),
        (PointerShape.grab, NSCursor.openHand), (PointerShape.grabbing, NSCursor.closedHand), (PointerShape.crosshair, NSCursor.crosshair),
        (PointerShape.resizeEW, NSCursor.resizeLeftRight), (PointerShape.resizeNS, NSCursor.resizeUpDown),
        (PointerShape.notAllowed, NSCursor.operationNotAllowed), (PointerShape.copy, NSCursor.dragCopy), (PointerShape.alias, NSCursor.dragLink)
    ].map { ($0.0, $0.1.image.tiffRepresentation) }

    init(bounds: CGRect, windowID: CGWindowID?, clock: CMClock?, writer: SegmentedCaptureWriter) {
        self.bounds = bounds; self.windowID = windowID; self.clock = clock ?? CMClockGetHostTimeClock(); self.writer = writer
    }

    @discardableResult func start() -> Bool {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]) { [weak self] event in
            // 官方保证监听闭包在主线程执行；读取事件原始时间，消除派发延迟。
            MainActor.assumeIsolated {
                let kind: PointerSample.Kind
                switch event.type {
                case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = .release
                case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: kind = .drag
                case .scrollWheel: kind = .scroll
                default: kind = .click
                }
                self?.sample(kind: kind, event: event)
            }
        }
        // 60 Hz 采样：与 60 fps 录制对齐，光标轨迹与自动聚焦的跟随判断更精细。
        timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample(kind: .move) }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        return monitor != nil
    }

    func stop() {
        if pendingScroll != .zero { sample(kind: .scroll) }
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        timer?.invalidate(); timer = nil
        wasInside = false
    }

    private func sample(kind: PointerSample.Kind, event: NSEvent? = nil) {
        // 高频游戏鼠标可能每秒派发上千次拖拽；限制拖拽事件，保留独立 60 Hz 位置采样。
        if kind == .drag {
            let time = ProcessInfo.processInfo.systemUptime
            guard time - lastDragTime >= 1.0 / 60 else { return }
            lastDragTime = time
        }
        // 滚轮增量累加后按 60 Hz 输出；定时位置采样负责刷新最后不足一帧的尾量。
        if kind == .scroll, let event {
            pendingScroll.x += event.scrollingDeltaX; pendingScroll.y += event.scrollingDeltaY
            let time = ProcessInfo.processInfo.systemUptime
            guard time - lastScrollTime >= 1.0 / 60 else { return }
            lastScrollTime = time
        }
        if kind == .move, pendingScroll != .zero { sample(kind: .scroll) }
        ticks += 1
        // 窗口可在录制中移动；每 0.1 秒刷新桌面几何，点击时立即刷新，窗口消失则跳过事件。
        if let windowID, ticks % 6 == 0 || kind == .click {
            guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]])?.first,
                  let value = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: value) else { bounds = .zero; leaveSource(); return }
            bounds = rect
        }
        let point = event?.cgEvent?.location ?? CGEvent(source: nil)?.location
        guard let point, bounds.width > 0, bounds.height > 0, bounds.contains(point) else { leaveSource(); return }
        let now = CMClockGetTime(clock).seconds
        let eventTime = event.map { now - max(0, ProcessInfo.processInfo.systemUptime - $0.timestamp) } ?? now
        let position = CGPoint(x: (point.x - bounds.minX) / bounds.width, y: (point.y - bounds.minY) / bounds.height)
        wasInside = true; lastPosition = position
        if let cursor = NSCursor.currentSystem {
            if ticks % 6 == 0 || kind == .click {
                let image = cursor.image.tiffRepresentation
                shape = knownCursors.first(where: { $0.1 == image })?.0 ?? .arrow
            }
            let bytes = cursor.image.tiffRepresentation
            if captured == nil || bytes != lastCursorImage || cursor.hotSpot != lastHotspot {
                captured = NativeCursorCapture.capture(cursor); lastCursorImage = bytes; lastHotspot = cursor.hotSpot
            }
        } else { shape = .arrow; captured = nil }
        var sample = PointerSample(time: eventTime, x: position.x, y: position.y, kind: kind)
        sample.shape = shape
        sample.cursorAssetID = captured?.id
        if kind == .click || kind == .release || kind == .drag { sample.button = event?.buttonNumber; if kind == .click { sample.clickCount = event?.clickCount } }
        if kind == .scroll { sample.scrollX = Double(pendingScroll.x); sample.scrollY = Double(pendingScroll.y); pendingScroll = .zero }
        writer.appendPointer(sample, cursor: captured)
    }

    /// 离开时只记录一次可见性变化；位置不越界，旧事件读取的坐标验证仍适用。
    private func leaveSource() {
        pendingScroll = .zero
        guard wasInside else { return }
        wasInside = false
        writer.appendPointer(PointerSample(time: CMClockGetTime(clock).seconds, x: lastPosition.x, y: lastPosition.y, kind: .exit))
    }
}

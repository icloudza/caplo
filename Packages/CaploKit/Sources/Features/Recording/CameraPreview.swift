import AppKit
import os
import AVFoundation
import CaptureKit
import CaploDesignSystem

/// 屏幕上的摄像头画中画：录制条阶段显示预览会话，录制中换成录制器的摄像头会话；只在有活的会话时显示，
/// 没有画面就整个隐藏（不显示占位假镜头）。窗口只隐藏不销毁，窗口号不变。圆形、镜像、可拖动。
/// 它只是录制阶段给用户看的取景窗：位置、大小、镜像都不写进工程，也不进片子；成片里人像放哪、多大、什么形状
/// 由编辑器的 `CameraLayout` 独立决定（新工程用它自己的默认值），录制时把它拖到哪都不影响编辑器。
@MainActor
enum CameraPreviewSession {
    static let size: CGFloat = 168
    static let inset: CGFloat = 24
    private static var panel: NSPanel?
    private static var view: CameraPreviewView?
    /// 默认停在显示器可见区域的右下角（避开程序坞），用户拖过就留在拖到的位置。
    static func frame(in visible: CGRect) -> CGRect {
        CGRect(x: visible.maxX - inset - size, y: visible.minY + inset, width: size, height: size)
    }

    static func show(feed: CameraFeed, on screen: NSScreen) {
        if panel == nil {
            let panel = NSPanel(contentRect: frame(in: screen.visibleFrame), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = StudioLevel.bar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isExcludedFromWindowsMenu = true
            panel.isMovableByWindowBackground = true
            panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            // 不可共享：画中画只给用户看，不进片子。
            panel.sharingType = .none
            let view = CameraPreviewView(frame: CGRect(origin: .zero, size: CGSize(width: size, height: size)))
            panel.contentView = view
            self.panel = panel; self.view = view
        }
        view?.attach(feed)
        if panel?.isVisible != true { panel?.orderFrontRegardless() }
    }

    /// 没有画面就隐藏；面板留着，下次直接再显示。
    static func hide() {
        view?.attach(nil)
        panel?.orderOut(nil)
    }
    static var isShowing: Bool { panel?.isVisible == true }
}

/// 圆形预览：自己把采集图的每一帧画上去（像素缓冲的 IOSurface 直接作图层内容，填满并镜像，像照镜子）。
/// 不用 AVCaptureVideoPreviewLayer：它在会话重配（换格式）时会清空内容黑一下；自己画就一直保留上一帧到新帧到来。
@MainActor
final class CameraPreviewView: NSView {
    private let picture = CALayer()
    private var attached: CameraFeed?
    /// 最新一帧在等主线程画：只留最新的，主线程忙时丢中间帧。
    private let pending = OSAllocatedUnfairLock<CameraFrame?>(initialState: nil)
    /// 正在显示的那帧要一直持有，IOSurface 的内容才不会被采集池回收覆盖。
    private var showing: CameraFrame?
    private var loggedUnsupported = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let layer else { return }
        layer.cornerRadius = frameRect.width / 2
        layer.masksToBounds = true
        layer.backgroundColor = NSColor.black.cgColor
        layer.borderWidth = 1.5
        layer.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        picture.contentsGravity = .resizeAspectFill
        picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        // 镜像：绕中心水平翻转。
        picture.transform = CATransform3DMakeScale(-1, 1, 1)
        picture.bounds = bounds
        picture.position = CGPoint(x: bounds.midX, y: bounds.midY)
        layer.addSublayer(picture)
    }
    required init?(coder: NSCoder) { fatalError("不支持归档初始化") }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.bounds = bounds
        picture.position = CGPoint(x: bounds.midX, y: bounds.midY)
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
    }

    /// 换采集图：同一条不重挂（借用时录制器用的就是预览这条）；nil 只停止收帧，画面留着直到面板隐藏。
    func attach(_ feed: CameraFeed?) {
        guard attached !== feed else { return }
        attached?.setPreviewSink(nil)
        attached = feed
        feed?.setPreviewSink { [weak self] frame in self?.enqueue(frame) }
    }

    /// 采集队列上：记下最新帧，主线程空了再画。
    nonisolated private func enqueue(_ frame: CameraFrame) {
        let idle = pending.withLock { slot -> Bool in let idle = slot == nil; slot = frame; return idle }
        guard idle else { return }
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    private func flush() {
        guard let frame = pending.withLock({ slot -> CameraFrame? in defer { slot = nil }; return slot }) else { return }
        guard let surface = CVPixelBufferGetIOSurface(frame.pixelBuffer)?.takeUnretainedValue() else {
            if !loggedUnsupported { loggedUnsupported = true; NSLog("Caplo：摄像头帧不带 IOSurface，画中画画不了") }
            return
        }
        showing = frame
        picture.contents = surface
    }
}

/// 决定画中画显示什么：录制中优先录制器的摄像头会话，否则预览会话；没有活的会话就隐藏。
/// 不看录制条窗口是否可见：按 REC 收起录制条的那一刻预览会话还在跑，画中画必须原地不动（否则先隐藏再显示会闪一下）；
/// 预览会话只在离开录制流程时才停，停了画中画自然隐藏。
/// 自己持续观察所有相关的可观察属性（会话何时起来、录制何时开始），录制条同步与窗口显隐再直接触发一次。
@MainActor
enum CameraPreviewCoordinator {
    private static var observing = false
    private static var lastVisible: Bool?

    static func startObserving() {
        guard !observing else { return }
        observing = true
        track()
    }

    private static func track() {
        withObservationTracking { refresh() } onChange: { Task { @MainActor in track() } }
    }

    static func refresh() {
        let recorder = ScreenRecorder.shared
        // 先把可观察的输入都读一遍，无论走哪条分支都建立跟踪。
        let busy = recorder.isBusy, usesCamera = recorder.sessionUsesCamera, recording = recorder.cameraPreviewFeed
        let preview = CameraMonitor.shared.feed
        let screen = StudioWindows.currentRecordBarModel?.targetScreen ?? NSScreen.main ?? NSScreen.screens[0]
        // 录制器借用的正是预览那条采集图，接上后对象相同，画面不断；倒计时期间预览采集图继续显示。
        let feed = (busy && usesCamera ? recording : nil) ?? preview
        let visible = feed != nil
        if visible != lastVisible {
            NSLog("Caplo：画中画%@（录制器%@，%@）", visible ? "显示" : "隐藏", busy ? "忙" : "空闲",
                  recording != nil ? "录制采集图" : preview != nil ? "预览采集图" : "无采集图")
            lastVisible = visible
        }
        if let feed { CameraPreviewSession.show(feed: feed, on: screen) } else { CameraPreviewSession.hide() }
    }
}

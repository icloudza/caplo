@preconcurrency import AVFoundation
import Observation

/// 录制条上的摄像头预览：摄像头一打开就起一路只用于显示的采集会话（720p，不写盘），界面上浮一个画中画让用户看到自己；
/// 按 REC 后不停：录制器借用这条采集图只挂帧消费者（`borrowFeed`），摄像头从打开到录完一直亮着。
/// 起不来按退避一直重试（连续互通的 iPhone 可能还在连接），采集中断自动重来。
@MainActor @Observable public final class CameraMonitor {
    public static let shared = CameraMonitor()
    /// 正在跑的采集图（画中画从它拿帧）；没起来时为 nil。
    public private(set) var feed: CameraFeed?
    public private(set) var active = false
    public private(set) var error: String?
    /// 正在预览的设备 uniqueID。
    public private(set) var deviceUID: String?
    private struct Configuration: Equatable { let deviceID: String?; let format: CameraFormat? }
    private var configuration: Configuration?
    private var generation = 0
    private var observer: NSObjectProtocol?
    private nonisolated let queue = DispatchQueue(label: "com.caplo.camera-preview", qos: .userInitiated)

    /// `deviceID` 为空用系统默认摄像头；`format` 为用户选的格式（nil 自动）。同一配置重复调用不重启，换格式才重起采集图。
    public func start(deviceID: String?, format: CameraFormat? = nil) {
        let wanted = Configuration(deviceID: deviceID, format: format)
        if configuration == wanted { return }
        // 同一台设备只换格式：在跑着的采集图上就地改，会话不停、画中画不黑；改不了才整个重起。
        if let current = configuration, current.deviceID == deviceID, active, let feed, let uid = feed.deviceID, let device = AVCaptureDevice(uniqueID: uid) {
            configuration = wanted
            let resolved = CameraFormat.resolve(available: CameraFormat.available(on: device), wanted: format)
            let run = generation
            queue.async { [weak self] in
                do { try feed.change(to: resolved) } catch {
                    NSLog("Caplo：摄像头就地换格式失败，改为重起：%@", error.localizedDescription)
                    Task { @MainActor in
                        guard let self, self.generation == run, self.configuration == wanted else { return }
                        self.configuration = nil
                        self.start(deviceID: deviceID, format: format)
                    }
                }
            }
            return
        }
        stop()
        configuration = wanted
        generation += 1
        run(wanted, run: generation)
    }

    public func stop() {
        generation += 1
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let feed { queue.async { feed.stop() } }
        feed = nil; deviceUID = nil; active = false; configuration = nil
    }

    /// 录制器借用：设备与（落实后的）格式一致且采集图在跑就交出去（录制器只挂消费者），否则 nil 让录制器自己起。
    func borrowFeed(for deviceID: String, format: CameraFormat?) -> CameraFeed? {
        guard active, deviceUID == deviceID, let feed, feed.isRunning(device: deviceID, format: format) else { return nil }
        return feed
    }

    private func run(_ configuration: Configuration, run: Int) {
        Task { [weak self] in
            guard await AVCaptureDevice.requestAccess(for: .video) else { self?.error = "摄像头访问未获允许。"; return }
            var delay = 1_500
            while true {
                guard let self, self.generation == run else { return }
                if await self.attempt(configuration, run: run) { return }
                try? await Task.sleep(for: .milliseconds(delay))
                delay = min(5_000, delay * 2)
            }
        }
    }

    /// 一轮尝试：会话的配置与启动在后台队列（startRunning 会阻塞），成功后把会话交给主线程发布。
    private func attempt(_ configuration: Configuration, run: Int) async -> Bool {
        // 不用 isConnected 预判（连续互通的 iPhone 刚出现时它可能还是假）：直接开输入，开不了就按退避再试。
        guard let device = configuration.deviceID.flatMap({ AVCaptureDevice(uniqueID: $0) }) ?? AVCaptureDevice.default(for: .video) else {
            error = "没有可用的摄像头。"; return false
        }
        // 采集图与录制完全同一套配置（含视频数据输出）：按 REC 时录制器只挂消费者，AVFoundation 那边什么都不改。
        let feed = CameraFeed(queue: queue)
        let format = CameraFormat.resolve(available: CameraFormat.available(on: device), wanted: configuration.format)
        let failure: String? = await withCheckedContinuation { continuation in
            queue.async {
                do { try feed.start(device, format: format); continuation.resume(returning: nil) }
                catch { feed.stop(); continuation.resume(returning: error.localizedDescription) }
            }
        }
        guard generation == run else { queue.async { feed.stop() }; return true }
        if let failure { if error != failure { NSLog("Caplo：摄像头预览起不来：%@", failure) }; error = failure; return false }
        NSLog("Caplo：摄像头预览已启动（%@，%@）", device.localizedName, format?.title ?? "预设 " + feed.session.sessionPreset.rawValue)
        self.feed = feed; deviceUID = device.uniqueID; active = true; error = nil
        observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: feed.session, queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "采集出错"
            NSLog("Caplo：摄像头预览中断，重来：%@", reason)
            Task { @MainActor in self?.interrupted("摄像头预览中断：\(reason)", run: run) }
        }
        return true
    }

    /// 采集中断（设备拔出等）：按原配置重新来。
    private func interrupted(_ message: String, run: Int) {
        guard generation == run, let configuration else { return }
        error = message
        stop()
        self.configuration = configuration
        generation += 1
        self.run(configuration, run: generation)
    }
}

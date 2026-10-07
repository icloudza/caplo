import AVFoundation
import os

public struct CaptureCamera: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// 摄像头的一种采集格式：尺寸 + 帧率，来自设备真实支持的格式表（像 FocuSee 那样列全）；预览与录制共用同一个选择。
public struct CameraFormat: Hashable, Sendable, Comparable {
    public let width: Int32
    public let height: Int32
    public let frameRate: Int
    public init(width: Int32, height: Int32, frameRate: Int) { self.width = width; self.height = height; self.frameRate = frameRate }

    /// 偏好里存的样子："1920x1080@30"；不认识的串为 nil（自动）。
    public var key: String { "\(width)x\(height)@\(frameRate)" }
    public init?(key: String?) {
        guard let key, let match = key.wholeMatch(of: /(\d+)x(\d+)@(\d+)/),
              let width = Int32(match.1), let height = Int32(match.2), let rate = Int(match.3), width > 0, height > 0, rate > 0 else { return nil }
        self.init(width: width, height: height, frameRate: rate)
    }
    public var title: String { "\(width) × \(height) · \(frameRate) fps" }
    public static func < (a: Self, b: Self) -> Bool {
        (Int(a.width) * Int(a.height), a.frameRate) < (Int(b.width) * Int(b.height), b.frameRate)
    }

    /// 列出的帧率档：设备范围盖住的才列；同一尺寸不同像素格式只算一条。
    static let listedFrameRates = [30, 60]
    public static func catalog(_ entries: [(width: Int32, height: Int32, frameRates: [ClosedRange<Double>])]) -> [CameraFormat] {
        var formats = Set<CameraFormat>()
        for entry in entries {
            for rate in listedFrameRates where entry.frameRates.contains(where: { $0.contains(Double(rate)) }) {
                formats.insert(CameraFormat(width: entry.width, height: entry.height, frameRate: rate))
            }
        }
        return formats.sorted()
    }

    /// 用户选的格式设备有就用它；没有（或没选）用默认：不超过 1080p 的最大尺寸、30 fps；再没有取最小的。
    public static func resolve(available: [CameraFormat], wanted: CameraFormat?) -> CameraFormat? {
        if let wanted, available.contains(wanted) { return wanted }
        let ordered = available.sorted()
        return ordered.last(where: { $0.height <= 1080 && $0.frameRate == 30 }) ?? ordered.first(where: { $0.frameRate == 30 }) ?? ordered.first
    }

    /// 设备真实支持的格式表。
    static func available(on device: AVCaptureDevice) -> [CameraFormat] {
        catalog(device.formats.map { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return (size.width, size.height, format.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate })
        })
    }

    /// 与所选尺寸 / 帧率对应的设备格式；同尺寸多种像素格式时优先 420v（采集管线最常用）。
    static func deviceFormat(on device: AVCaptureDevice, matching format: CameraFormat) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { candidate in
            let size = CMVideoFormatDescriptionGetDimensions(candidate.formatDescription)
            return size.width == format.width && size.height == format.height
                && candidate.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(format.frameRate) && Double(format.frameRate) <= $0.maxFrameRate }
        }
        return candidates.first { CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange } ?? candidates.first
    }
}

/// 发现设备不启动采集；只有明确开始摄像头录制时才申请视频权限。
@MainActor
public enum CameraInputCatalog {
    public static func cameras() -> [CaptureCamera] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
            .devices.map { CaptureCamera(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 所选摄像头（空 id 为系统默认）真实支持的格式表；没有设备返回空。
    public static func formats(for deviceID: String?) -> [CameraFormat] {
        device(for: deviceID).map(CameraFormat.available(on:)) ?? []
    }
    static func device(for deviceID: String?) -> AVCaptureDevice? {
        if let deviceID, !deviceID.isEmpty { return AVCaptureDevice(uniqueID: deviceID) }
        return AVCaptureDevice.default(for: .video)
    }
}

struct RecordingCameraPlan: Equatable, Sendable {
    let deviceID: String?
    /// 用户选的格式（nil 为自动），启动时再按设备真实格式表落实。
    var format: CameraFormat? = nil

    static func resolve(enabled: Bool, selectedID: String?, cameras: [CaptureCamera], defaultID: String?, format: CameraFormat? = nil) throws -> Self {
        guard enabled else { return Self(deviceID: nil) }
        guard let chosen = selectedID ?? defaultID, cameras.contains(where: { $0.id == chosen }) else {
            throw RecordingError.message(String(localized: "所选摄像头未连接。请选择可用设备，或关闭摄像头后录制。"))
        }
        return Self(deviceID: chosen, format: format)
    }
}

/// 一路摄像头采集图：会话 + 设备输入 + BGRA 视频数据输出，录制条预览与录制共用同一套配置（预设阶梯、30 fps、不镜像）。
/// 帧交给当前的消费者（录制时是 `CameraCapture`），没有消费者就丢掉；消费者来去不改会话，摄像头不灭不重开、画面不断。
/// 配置、启停与回调全部在 `queue` 上。
public final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue: DispatchQueue
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    /// 画中画自绘用的帧出口：每帧在采集队列上调用，接收方自己节流并回主线程画；与录制消费者互不影响。
    /// 画中画不用 AVCaptureVideoPreviewLayer（它在会话重配、换格式时会清空内容黑一下），自己拿帧画就能一直保留上一帧。
    private let previewSink = OSAllocatedUnfairLock<(@Sendable (CameraFrame) -> Void)?>(initialState: nil)
    public func setPreviewSink(_ sink: (@Sendable (CameraFrame) -> Void)?) { previewSink.withLock { $0 = sink } }
    public var hasPreviewSink: Bool { previewSink.withLock { $0 != nil } }
    /// 设备与落实后的采集格式（format 为 nil 表示设备没有格式表，退回预设阶梯）；队列上写、任意线程读。
    private let info = OSAllocatedUnfairLock<(deviceID: String?, format: CameraFormat?)>(initialState: (nil, nil))
    var deviceID: String? { info.withLock { $0.deviceID } }
    var format: CameraFormat? { info.withLock { $0.format } }
    /// 只在 `queue` 上读写。
    var consumer: CameraFrameConsumer?
    private var loggedFrame = false

    public init(queue: DispatchQueue) { self.queue = queue }

    var isRunning: Bool { session.isRunning }
    func isRunning(device: String, format: CameraFormat?) -> Bool { session.isRunning && deviceID == device && self.format == format }

    /// `format` 是已经按设备格式表落实的选择；nil 时走预设阶梯（1080p → 720p → high，30 fps）。
    func start(_ device: AVCaptureDevice, format: CameraFormat?) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        try configure(device, format: format)
        let uid = device.uniqueID
        info.withLock { $0 = (uid, format) }
        session.startRunning()
        guard session.isRunning else { throw RecordingError.message(String(localized: "无法启动摄像头，请检查设备是否被占用。")) }
        logFormat(device)
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        consumer = nil
        output.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        info.withLock { $0 = (nil, nil) }
    }

    /// 在跑着的采集图上换格式：不停会话、不换输入，只改设备的 activeFormat 与帧时长；预览图层保持画面不黑，
    /// 消费者也不用摘。格式没变就什么都不做。
    func change(to format: CameraFormat?) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { throw RecordingError.message(String(localized: "采集图还没有摄像头输入。")) }
        guard format != self.format else { return }
        session.beginConfiguration()
        do { try applyFormat(device, format: format) } catch { session.commitConfiguration(); throw error }
        session.commitConfiguration()
        info.withLock { $0.format = format }
        loggedFrame = false
        logFormat(device)
    }

    /// 提交后设备真正的 activeFormat，与出帧尺寸一起对照。
    private func logFormat(_ device: AVCaptureDevice) {
        let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let rate = device.activeVideoMinFrameDuration.seconds > 0 ? 1 / device.activeVideoMinFrameDuration.seconds : 0
        NSLog("Caplo：摄像头格式已提交（所选 %@；设备 activeFormat %d × %d @ %.0f fps；预设 %@）",
              format?.title ?? String(localized: "预设阶梯"), size.width, size.height, rate, session.sessionPreset.rawValue)
    }

    private func configure(_ device: AVCaptureDevice, format: CameraFormat?) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecordingError.message(String(localized: "无法添加摄像头输入。")) }
        session.addInput(input)
        try applyFormat(device, format: format)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        guard session.canAddOutput(output) else { throw RecordingError.message(String(localized: "无法添加摄像头画面输出。")) }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            // 原素材保持未镜像，左右翻转交给非破坏性画中画布局，避免重复翻转。
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    /// 精确按设备格式采集：macOS 没有 inputPriority 预设，会话留在默认的 high（不指定尺寸）时按设备的 activeFormat 出帧。
    /// 不要在同一次提交里再赋值预设——预设"改变"会让会话在提交时重选格式，盖掉刚设的 activeFormat；
    /// 只有之前退到过具体预设时才先单独提交一次回到 high。没有格式表退回预设阶梯。在 beginConfiguration 里调用。
    private func applyFormat(_ device: AVCaptureDevice, format: CameraFormat?) throws {
        if let format, let deviceFormat = CameraFormat.deviceFormat(on: device, matching: format) {
            if session.sessionPreset != .high {
                session.commitConfiguration()
                session.sessionPreset = .high
                session.beginConfiguration()
            }
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = deviceFormat
            let duration = CMTime(value: 1, timescale: CMTimeScale(format.frameRate))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } else {
            Self.applyPreset(session)
            try Self.lockFrameRate(device)
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let image = sampleBuffer.imageBuffer {
            // 起来与换格式后各记一次真实尺寸，供实机核对。
            if !loggedFrame {
                loggedFrame = true
                NSLog("Caplo：摄像头出帧 %d × %d（所选 %@）", CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image), format?.title ?? "预设")
            }
            if let sink = previewSink.withLock({ $0 }) { sink(CameraFrame(pixelBuffer: image)) }
        }
        consumer?.receive(sampleBuffer, from: session)
    }

    /// 没有格式表时的退路：优先 1080p，再退到 720p；都不行用 high。
    static func applyPreset(_ session: AVCaptureSession) {
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        else if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        else { session.sessionPreset = .high }
    }

    /// 支持 30 fps 就锁 30；已经是 30 不再动设备。
    static func lockFrameRate(_ device: AVCaptureDevice) throws {
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) else { return }
        let target = CMTime(value: 1, timescale: 30)
        guard device.activeVideoMinFrameDuration != target || device.activeVideoMaxFrameDuration != target else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeVideoMinFrameDuration = target
        device.activeVideoMaxFrameDuration = target
    }
}

/// 交给画中画画的一帧：像素缓冲来自采集输出（BGRA、IOSurface 背景），接收方持有到下一帧到来。
public struct CameraFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
}

/// 采集图的帧消费者；在采集图的队列上被调用。
protocol CameraFrameConsumer: AnyObject {
    func receive(_ sample: CMSampleBuffer, from session: AVCaptureSession)
}

/// 录制时的摄像头消费者：把采集图交来的帧换算到主机时钟写进分段写入器，看护帧流与设备断开。
/// 录制条已经在预览同一台摄像头时借用它的采集图（`adopting`），只是挂上消费者，AVFoundation 那边什么都不改；
/// 否则自己建一路。仅创建视频输入；麦克风仍由录制会话独立选择，不能隐式启用摄像头自带的声音。
final class CameraCapture: CameraFrameConsumer, @unchecked Sendable {
    private var feed: CameraFeed
    private var queue: DispatchQueue { feed.queue }
    /// 借用录制条预览采集图时为真：停止时只摘消费者，采集图继续给预览用。
    private var borrowed = false
    private let writer: SegmentedCaptureWriter
    private let pendingFrames = DispatchSemaphore(value: 2)
    private let onFailure: @Sendable (String) -> Void
    private var observers: [NSObjectProtocol] = []
    private var watchdog: DispatchSourceTimer?
    private var active = false
    private var consumed = false
    private var failed = false
    private var startedAt = 0.0
    private var lastFrameAt: Double?

    init(writer: SegmentedCaptureWriter, onFailure: @escaping @Sendable (String) -> Void) {
        self.writer = writer; self.onFailure = onFailure
        feed = CameraFeed(queue: DispatchQueue(label: "com.caplo.camera", qos: .userInitiated))
    }

    /// 给屏幕上的画中画用；借用时就是录制条一直在画的那条采集图。
    var previewFeed: CameraFeed { feed }

    /// `format`：已按设备格式表落实的选择（nil 走预设阶梯）。`adopting`：录制条阶段已经在跑的采集图（同一设备、同一格式），
    /// 有就只挂消费者，摄像头不灭不重开；没有才自己建。
    func start(deviceID: String, format: CameraFormat? = nil, adopting shared: CameraFeed? = nil) async throws {
        try Task.checkCancellation()
        // 借用在任何回调之前定下来，之后所有工作都在那条采集图的队列上。
        if let shared { feed = shared; borrowed = true }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    guard !consumed else { throw RecordingError.message(String(localized: "摄像头会话已使用，请重新开始录制。")) }
                    consumed = true
                    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                        throw RecordingError.message(String(localized: "摄像头访问未获允许，请在系统设置中开启权限。"))
                    }
                    guard let device = AVCaptureDevice(uniqueID: deviceID), device.hasMediaType(.video), device.isConnected else {
                        throw RecordingError.message(String(localized: "所选摄像头已断开，请重新选择设备。"))
                    }
                    if borrowed, !feed.isRunning(device: deviceID, format: format) {
                        // 借来的采集图已经不在跑（设备刚拔掉等）：自己起一路，不让录制失败。
                        let queue = queue
                        borrowed = false; feed = CameraFeed(queue: queue)
                    }
                    if borrowed { NSLog("Caplo：摄像头沿用录制条的预览采集，不重开") } else { try feed.start(device, format: format) }
                    feed.consumer = self
                    observe(deviceID: deviceID)
                    active = true
                    startedAt = ProcessInfo.processInfo.systemUptime
                    startWatchdog()
                    continuation.resume()
                } catch {
                    stopOnQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
        if Task.isCancelled { await stop(); throw CancellationError() }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in stopOnQueue(); continuation.resume() }
        }
    }

    func receive(_ sampleBuffer: CMSampleBuffer, from session: AVCaptureSession) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard active, !failed, sampleBuffer.isValid, sampleBuffer.imageBuffer != nil else { return }
        do {
            // AVFoundation 的输出时间属于会话时钟，先换算成屏幕、声音、鼠标共用的主机时钟。
            guard let clock = session.synchronizationClock else { throw RecordingError.message(String(localized: "摄像头同步时钟不可用。")) }
            let frame = CameraFrameTransfer(sample: try MediaClockBridge.retime(sampleBuffer, from: clock))
            lastFrameAt = ProcessInfo.processInfo.systemUptime
            // 编码繁忙时最多排队两帧，避免摄像头回调把像素缓冲无限堆到屏幕队列。
            guard pendingFrames.wait(timeout: .now()) == .success else { return }
            writer.queue.async { [writer, pendingFrames] in
                defer { pendingFrames.signal() }
                writer.ingest(frame.sample, role: .camera)
            }
        } catch { fail(error.localizedDescription) }
    }

    private func observe(deviceID: String) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: feed.session, queue: nil) { [weak self] notification in
            let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? String(localized: "摄像头采集发生错误。")
            self?.enqueueFailure(message)
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] notification in
            guard (notification.object as? AVCaptureDevice)?.uniqueID == deviceID else { return }
            self?.enqueueFailure(String(localized: "摄像头已断开，已结束录制并保存已收到的内容。"))
        })
    }

    private func enqueueFailure(_ message: String) {
        queue.async { [weak self] in self?.fail(message) }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, self.active else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - (self.lastFrameAt ?? self.startedAt) > (self.lastFrameAt == nil ? 8 : 3) {
                self.fail(String(localized: "摄像头未持续提供画面，已结束录制并保留现有素材。"))
            }
        }
        watchdog = timer
        timer.resume()
    }

    private func fail(_ message: String) {
        guard active, !failed else { return }
        failed = true
        onFailure(message)
    }

    private func stopOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        consumed = true; active = false
        watchdog?.cancel(); watchdog = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if feed.consumer === self { feed.consumer = nil }
        // 借来的采集图只摘消费者，摄像头继续给录制条的预览用，不灭。
        if !borrowed { feed.stop() }
    }
}

/// Core Media 尚未声明 Sendable；此封装仅跨队列转交只读样本，并持有像素缓冲直到编码完成。
/// 创建之后任何一端都不修改样本时序、附件或像素，不能用于传递可变采集状态。
private struct CameraFrameTransfer: @unchecked Sendable {
    let sample: CMSampleBuffer
}

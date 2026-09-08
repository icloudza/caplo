import AVFoundation

public struct CaptureCamera: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// 发现设备不启动采集；只有明确开始摄像头录制时才申请视频权限。
@MainActor
public enum CameraInputCatalog {
    public static func cameras() -> [CaptureCamera] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
            .devices.map { CaptureCamera(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct RecordingCameraPlan: Equatable, Sendable {
    let deviceID: String?

    static func resolve(enabled: Bool, selectedID: String?, cameras: [CaptureCamera], defaultID: String?) throws -> Self {
        guard enabled else { return Self(deviceID: nil) }
        guard let chosen = selectedID ?? defaultID, cameras.contains(where: { $0.id == chosen }) else {
            throw RecordingError.message("所选摄像头未连接。请选择可用设备，或关闭摄像头后录制。")
        }
        return Self(deviceID: chosen)
    }
}

/// 摄像头的配置、启停和帧回调全部在独立串行队列，不阻塞主线程或屏幕编码队列。
/// 仅创建视频输入；麦克风仍由录制会话独立选择，不能隐式启用摄像头自带的声音。
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.caplo.camera", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
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
    }

    func start(deviceID: String) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    guard !consumed else { throw RecordingError.message("摄像头会话已使用，请重新开始录制。") }
                    consumed = true
                    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                        throw RecordingError.message("摄像头访问未获允许，请在系统设置中开启权限。")
                    }
                    guard let device = AVCaptureDevice(uniqueID: deviceID), device.hasMediaType(.video), device.isConnected else {
                        throw RecordingError.message("所选摄像头已断开，请重新选择设备。")
                    }
                    try configure(device)
                    observe(deviceID: deviceID)
                    active = true
                    startedAt = ProcessInfo.processInfo.systemUptime
                    session.startRunning()
                    guard session.isRunning else { throw RecordingError.message("无法启动摄像头，请检查设备是否被占用。") }
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

    private func configure(_ device: AVCaptureDevice) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // 优先 1080p，再退到 720p；独立人像无需沿用屏幕的 4K 尺寸。
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecordingError.message("无法添加摄像头输入。") }
        session.addInput(input)
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        else if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        else { session.sessionPreset = .high }
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        guard session.canAddOutput(output) else { throw RecordingError.message("无法添加摄像头画面输出。") }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            // 原素材保持未镜像，左右翻转交给非破坏性画中画布局，避免重复翻转。
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard active, !failed, sampleBuffer.isValid, sampleBuffer.imageBuffer != nil else { return }
        do {
            // AVFoundation 的输出时间属于会话时钟，先换算成屏幕、声音、鼠标共用的主机时钟。
            guard let clock = session.synchronizationClock else { throw RecordingError.message("摄像头同步时钟不可用。") }
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
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
            let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "摄像头采集发生错误。"
            self?.enqueueFailure(message)
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] notification in
            guard (notification.object as? AVCaptureDevice)?.uniqueID == deviceID else { return }
            self?.enqueueFailure("摄像头已断开，已结束录制并保存已收到的内容。")
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
                self.fail("摄像头未持续提供画面，已结束录制并保留现有素材。")
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
        output.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
    }
}

/// Core Media 尚未声明 Sendable；此封装仅跨队列转交只读样本，并持有像素缓冲直到编码完成。
/// 创建之后任何一端都不修改样本时序、附件或像素，不能用于传递可变采集状态。
private struct CameraFrameTransfer: @unchecked Sendable {
    let sample: CMSampleBuffer
}

import AVFoundation
import ScreenCaptureKit
import ProjectKit
import EditingCore

/// 单条素材使用独立文件与共同的会话起点，音频无需在录制阶段混合。
/// 写入期间的状态只由采集队列修改；移出采集路由并完成编码后，提交队列只读取冻结结果。
private final class TrackFile: @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let path: String
    let videoSize: CGSize?
    let start: CMTime
    var count = 0
    var lastPTS = CMTime.invalid
    var failure: String?

    init(project: URL, index: Int, role: MediaRole, width: Int, height: Int, start: CMTime, frameRate: Double = 30) throws {
        path = String(format: "Media/%06d-%@.mov", index, role.rawValue)
        videoSize = role.isVideo ? CGSize(width: width, height: height) : nil
        self.start = start
        writer = try AVAssetWriter(outputURL: project.appendingPathComponent(path), fileType: .mov)
        if role.isVideo {
            let rate = max(24, min(120, frameRate.isFinite ? frameRate : 30))
            input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                // 两类视频统一声明 SDR / BT.709，避免无标记摄像头文件被静帧解码器按 NTSC 色域解释。
                AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
                // 码率随帧率等比放大；关闭帧重排降低编码延迟，关键帧固定 2 秒便于拖动定位。
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: min(60_000_000, max(4_000_000, Int(Double(width * height) * 5 * rate / 30))),
                    AVVideoMaxKeyFrameIntervalKey: Int(rate * 2),
                    AVVideoExpectedSourceFrameRateKey: Int(rate),
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ]
            ])
        } else {
            // 原素材采用 PCM，避免每个短片段产生独立 AAC 编码延迟；AAC 仅在最终导出时编码。
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: role == .systemAudio ? 2 : 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
            ])
        }
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingError.message(String(localized: "无法创建 \(role.rawValue) 编码轨道。")) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RecordingError.message(String(localized: "无法写入素材。")) }
        writer.startSession(atSourceTime: start)
    }

    func append(_ sample: CMSampleBuffer, audio: Bool) throws {
        let pts = sample.presentationTimeStamp
        guard !lastPTS.isValid || pts > lastPTS else { return }
        guard input.isReadyForMoreMediaData else {
            if writer.status == .failed { throw writer.error ?? RecordingError.message(String(localized: "素材写入失败。")) }
            // 音频不允许静默丢失；持续积压将损害同步，直接错误收尾并保留已提交片段。
            if audio { throw RecordingError.message(String(localized: "音频写入跟不上采集速度，请检查磁盘空间和系统负载。")) }
            return
        }
        guard input.append(sample) else { throw writer.error ?? RecordingError.message(String(localized: "无法追加素材数据。")) }
        lastPTS = pts
        count += 1
    }

    func finish(at end: CMTime, completion: @escaping @Sendable (String?) -> Void) {
        guard count > 0 else { writer.cancelWriting(); completion(nil); return }
        writer.endSession(atSourceTime: end)
        input.markAsFinished()
        writer.finishWriting { [self] in
            completion(writer.status == .completed ? nil : (writer.error?.localizedDescription ?? String(localized: "素材收尾失败。")))
        }
    }
}

private final class OpenSegment: @unchecked Sendable {
    let index: Int
    let start: CMTime
    var end: CMTime?
    var tracks: [MediaRole: TrackFile] = [:]
    var events: [PointerSample] = []
    init(index: Int, start: CMTime) { self.index = index; self.start = start }
}

/// 共用串行采集队列与单一时钟。最多保留当前片段及一组正在提交的片段，限制编码资源增长。
/// 暂停后不写入样本；继续时使用新的起点，工程时长只累计实际录制区间。
final class SegmentedCaptureWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.caplo.segment-capture", qos: .userInitiated)
    private let commitQueue = DispatchQueue(label: "com.caplo.segment-commit", qos: .utility)
    private let group = DispatchGroup()
    private let project: URL
    private let width: Int
    private let height: Int
    private let roles: [MediaRole]
    private let frameRate: Double
    private let segmentSeconds: Double
    private let onStarted: @Sendable () -> Void
    private let onFailure: @Sendable (String) -> Void
    private var current: OpenSegment?
    private var retiring: [OpenSegment] = []
    private var index = 0
    private var pending = 0
    private var stopped = false
    private var paused = false
    private var didStart = false
    private var reportedFailure: String?
    private var latestFrame: CMSampleBuffer?
    private var latestCameraFrame: CMSampleBuffer?
    /// 继续录制时积压已满，等提交降下来再开段：记下应当从哪一刻接着录。
    /// 等待期间到达的样本没有片段可写，新段从它们之后开始，时间轴上不留空洞。
    private var resumeFrom: CMTime?
    private var timer: DispatchSourceTimer?
    private var clock: CMClock = CMClockGetHostTimeClock()
    /// 同时在收尾、提交的旧片段上限。到了上限还要换段就结束录制（保护已提交的部分）。
    /// 原来是 2：慢盘、外置盘上一段的收尾加提交偶尔超过 10 秒，长录制会被中途结束；4 段留出约 40 秒余量。
    static let maximumPendingSegments = 4

    init(project: URL, width: Int, height: Int, systemAudio: Bool, microphone: Bool, camera: Bool = false, frameRate: Double = 30, segmentSeconds: Double = 10,
         onStarted: @escaping @Sendable () -> Void, onFailure: @escaping @Sendable (String) -> Void) {
        self.project = project; self.width = width; self.height = height
        self.frameRate = frameRate
        self.segmentSeconds = segmentSeconds
        roles = [.screen] + (systemAudio ? [.systemAudio] : []) + (microphone ? [.microphone] : []) + (camera ? [.camera] : [])
        self.onStarted = onStarted; self.onFailure = onFailure
    }

    /// 和媒体共用队列及片段边界；每段（10 秒）最多 6000 个事件，内存不会随录制时长增长。
    /// 60 Hz 位置 + 60 Hz 拖拽 + 60 Hz 滚轮同时进行一段也只有约 1800 个；以前上限 2000 贴得太近。
    /// 点击与松开不受上限约束：自动镜头靠它们，丢了就少一个镜头。
    static let maximumEventsPerSegment = 6000
    private var savedCursors = Set<String>()
    private var cursorBytes = 0
    func appendPointer(_ sample: PointerSample, cursor: CapturedCursor? = nil) {
        queue.async { [self] in
            guard !stopped, !paused else { return }
            var sample = sample
            if let cursor, !savedCursors.contains(cursor.id) {
                if savedCursors.count < 2048 && cursorBytes + cursor.png.count <= 48 * 1_048_576 {
                    savedCursors.insert(cursor.id); cursorBytes += cursor.png.count
                    // 光标图写盘放到提交队列：不在采集队列上做文件读写，画面与声音的写入不会被它挡住。
                    // 写失败只是那一款光标按样式回退（读取端缺文件即跳过），不影响录制。
                    let project = self.project
                    commitQueue.async {
                        do { try CursorStorage.save(cursor, in: project) } catch { NSLog("Caplo：光标图写入失败：%@", error.localizedDescription) }
                    }
                } else { sample.cursorAssetID = nil }
            }
            for segment in retiring + (current.map { [$0] } ?? []) {
                guard sample.time >= segment.start.seconds,
                      segment.end == nil || sample.time < segment.end!.seconds,
                      segment.events.count < Self.maximumEventsPerSegment || sample.kind == .click || sample.kind == .release else { continue }
                var local = sample; local.time -= segment.start.seconds
                segment.events.append(local)
            }
        }
    }

    func startTimer(clock: CMClock?) {
        queue.async { [self] in
            self.clock = clock ?? CMClockGetHostTimeClock()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
            timer.setEventHandler { [weak self] in
                guard let self, let current = self.current, !self.paused, !self.stopped else { return }
                let now = CMClockGetTime(self.clock)
                if (now - current.start).seconds >= self.segmentSeconds {
                    self.perform { try self.rotate(at: current.start + CMTime(seconds: self.segmentSeconds, preferredTimescale: 48_000)) }
                }
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, sampleBuffer.presentationTimeStamp.isNumeric else { return }
        if type == .screen {
            guard let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  info.first?[.status] as? Int == SCFrameStatus.complete.rawValue else { return }
        }
        let role: MediaRole
        switch type { case .screen: role = .screen; case .audio: role = .systemAudio; case .microphone: role = .microphone; @unknown default: return }
        perform {
            let aligned = try MediaClockBridge.retime(sampleBuffer, from: stream.synchronizationClock ?? CMClockGetHostTimeClock())
            ingest(aligned, role: role)
        }
    }

    /// 测试与采集使用相同入口；仅允许在采集队列调用。
    func ingest(_ sample: CMSampleBuffer, role: MediaRole) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped, roles.contains(role), sample.isValid, sample.presentationTimeStamp.isNumeric, reportedFailure == nil else { return }
        if let from = resumeFrom, current == nil, !paused {
            let end = sample.presentationTimeStamp + (sample.duration.isNumeric ? sample.duration : .zero)
            if end > from { resumeFrom = end }
        }
        perform {
            // 任一视频到达下一边界都先换段；不能等屏幕回调，否则先到的摄像头帧会被旧段尾裁掉。
            if role.isVideo, !paused, let segment = current,
               (sample.presentationTimeStamp - segment.start).seconds >= segmentSeconds {
                try rotate(at: segment.start + CMTime(seconds: segmentSeconds, preferredTimescale: 48_000))
            }
            if current == nil && !paused && role == .screen {
                try begin(at: sample.presentationTimeStamp)
                try seedCamera(at: sample.presentationTimeStamp)
            }
            // 换段之后再记住这一帧：换段用的段首快照必须是边界之前的画面（与摄像头同一规则），
            // 以前先记后换，边界后到的帧会被提前到边界时刻显示。
            if role == .screen, latestFrame == nil || sample.presentationTimeStamp > latestFrame!.presentationTimeStamp { latestFrame = sample }
            // 换段快照先使用边界之前的帧，再记住当前帧，防止后来的画面被提前显示。
            if role == .camera, latestCameraFrame == nil || sample.presentationTimeStamp > latestCameraFrame!.presentationTimeStamp {
                latestCameraFrame = sample
            }
            // 跨边界的音频包同时交给相邻文件，AVAssetWriter 的会话起止负责精确裁切。
            // 这也支持非交错 PCM，不依赖只接受交错样本的 CopySampleBufferForRange。
            let candidates = retiring + (current.map { [$0] } ?? [])
            for segment in candidates {
                let pts = sample.presentationTimeStamp
                let duration = sample.duration.isNumeric ? sample.duration : .zero
                guard pts + duration >= segment.start, segment.end == nil || pts < segment.end! else { continue }
                if paused && segment.end == nil { continue }
                if role == .camera {
                    // 视频不能把边界前的帧回填到未来；仅边界处的显式快照可以延续已显示的画面。
                    guard pts >= segment.start else { continue }
                    try appendCamera(sample, to: segment)
                } else {
                    try segment.tracks[role]?.append(sample, audio: !role.isVideo)
                }
            }
            if !didStart, (current?.tracks[.screen]?.count ?? 0) > 0 {
                didStart = true
                onStarted()
            }
        }
    }

    private func begin(at time: CMTime) throws {
        resumeFrom = nil
        let segment = OpenSegment(index: index, start: time)
        index += 1
        for role in roles where role != .camera {
            segment.tracks[role] = try TrackFile(project: project, index: segment.index, role: role, width: width, height: height, start: time, frameRate: frameRate)
        }
        current = segment
    }

    /// 以每段第一帧的实际尺寸创建摄像头编码器，不能沿用屏幕分辨率导致人像拉伸。
    /// 未收到摄像头画面的区间不创建空视频，也不伪造首帧时间。
    private func appendCamera(_ sample: CMSampleBuffer, to segment: OpenSegment) throws {
        guard let pixel = sample.imageBuffer else { throw RecordingError.message(String(localized: "摄像头未提供有效视频画面。")) }
        if segment.tracks[.camera] == nil {
            let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
            guard width >= 2, height >= 2, width <= 4096, height <= 4096, width % 2 == 0, height % 2 == 0 else {
                throw RecordingError.message(String(localized: "摄像头输出尺寸不支持，请选择标准视频格式。"))
            }
            // 摄像头文件从实际首帧开始；它在片段中的偏移另外记录，避免编码器补黑被误当成有效画面。
            segment.tracks[.camera] = try TrackFile(project: project, index: segment.index, role: .camera, width: width, height: height, start: sample.presentationTimeStamp)
        }
        guard segment.tracks[.camera]?.videoSize == CGSize(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel)) else {
            // 摄像头中途换了画面尺寸（连续互通相机转向、切换格式）：一个编码器只能是一种尺寸，
            // 以前直接结束整段录制。现在就地换段，新段用新尺寸建摄像头文件；退役中的旧段只丢掉这一帧。
            // 段首 0.1 秒内不换（片段至少要有时长），先丢帧，下一帧再换。
            guard segment === current, !paused, (sample.presentationTimeStamp - segment.start).seconds >= 0.1 else { return }
            try rotate(at: sample.presentationTimeStamp)
            // 还没有屏幕帧时换不了段（rotate 原样返回）：丢掉这一帧，不能对同一段再追加一次——那会无限递归。
            if let fresh = current, fresh !== segment { try appendCamera(sample, to: fresh) }
            return
        }
        try segment.tracks[.camera]?.append(sample, audio: false)
    }

    private func seedCamera(at time: CMTime) throws {
        guard let current, let frame = latestCameraFrame else { return }
        let age = (time - frame.presentationTimeStamp).seconds
        // 只延续边界附近的帧；断流或长暂停不能用旧人像掩盖缺失视频。
        guard age >= 0, age <= 0.5 else { return }
        try appendCamera(Self.retime(frame, to: time), to: current)
    }

    private func rotate(at time: CMTime) throws {
        guard let old = current, let frame = latestFrame else { return }
        guard pending < Self.maximumPendingSegments else { throw RecordingError.message(String(localized: "片段保存持续积压，已结束录制以保护现有素材。")) }
        old.end = time
        retire(old)
        current = nil
        try begin(at: time)
        // 静止画面可能没有新帧，复制最后画面的时间戳以保持下一片段可解码。
        try current?.tracks[.screen]?.append(Self.retime(frame, to: time, frameRate: frameRate), audio: false)
        try seedCamera(at: time)
    }

    private func retire(_ segment: OpenSegment) {
        retiring.append(segment)
        pending += 1
        group.enter()
        // 给跨队列到达的音频包保留短暂提交窗口，最多保留有限数量的旧片段。
        queue.asyncAfter(deadline: .now() + 0.35) { [self] in
            retiring.removeAll { $0 === segment }
            let finishing = DispatchGroup()
            let errors = SegmentErrors()
            for track in segment.tracks.values {
                finishing.enter()
                track.finish(at: segment.end!) { message in
                    if let message { errors.append(message) }
                    finishing.leave()
                }
            }
            finishing.notify(queue: commitQueue) { [self] in
                var issue = errors.first
                if issue == nil {
                    do {
                        let files = segment.tracks.filter { $0.value.count > 0 }.mapValues(\.path)
                        guard files[.screen] != nil else { throw RecordingError.message(String(localized: "当前片段没有有效视频。")) }
                        let duration = (segment.end! - segment.start).seconds
                        var record = SegmentRecord(id: segment.index, duration: duration, files: files)
                        let offsets = segment.tracks.filter { $0.value.count > 0 && $0.value.start > segment.start }
                            .mapValues { ($0.start - segment.start).seconds }
                        if !offsets.isEmpty { record.mediaOffsets = offsets }
                        if !segment.events.isEmpty {
                            // 无损压缩后约为明文的 1/12（见 PointerEventFile）；在提交队列上做，不占采集队列。
                            let path = String(format: "Events/%06d.", segment.index) + PointerEventFile.pathExtension
                            try PointerEventFile.data(for: segment.events.filter { $0.time < duration }).write(to: project.appendingPathComponent(path), options: .atomic)
                            record.eventsPath = path
                        }
                        try ProjectStorage.commit(record, to: project)
                    } catch { issue = error.localizedDescription }
                }
                let result = issue
                queue.async { [self] in
                    pending -= 1
                    if let result { fail(result) }
                    if let from = resumeFrom, pending < Self.maximumPendingSegments, current == nil, !paused, !stopped, reportedFailure == nil {
                        resumeSegment(at: from)
                    }
                    group.leave()
                }
            }
        }
    }

    func pause(at time: CMTime) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                paused = true
                resumeFrom = nil
                if let current {
                    current.end = CMTimeMaximum(time, current.start + CMTime(value: 1, timescale: 30))
                    retire(current)
                    self.current = nil
                }
                continuation.resume()
            }
        }
    }

    func resume(at time: CMTime) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !stopped else { continuation.resume(); return }
                paused = false
                // 暂停刚把一段送去提交、前一段还没提交完时，立刻开新段会让积压越过上限。
                // 这不是故障：先记下继续的时刻，等提交降下来再开段（期间有新画面到达时 ingest 会先开段）。
                // 以前这里直接报错，整段录制随之结束。
                if pending >= Self.maximumPendingSegments { resumeFrom = time } else { resumeSegment(at: time) }
                continuation.resume()
            }
        }
    }

    /// 从 `time` 起开新段，并用最后一帧画面垫在段首：静止的屏幕可能很久没有新帧，没有首帧的片段无法解码。
    private func resumeSegment(at time: CMTime) {
        resumeFrom = nil
        guard let latestFrame else { return }
        perform {
            try begin(at: time)
            try current?.tracks[.screen]?.append(Self.retime(latestFrame, to: time, frameRate: frameRate), audio: false)
        }
    }

    func finish(at time: CMTime) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard !stopped else { continuation.resume(throwing: RecordingError.message(String(localized: "录制已停止。"))); return }
                stopped = true
                timer?.cancel(); timer = nil
                if let current {
                    current.end = CMTimeMaximum(time, current.start + CMTime(value: 1, timescale: 30))
                    retire(current)
                    self.current = nil
                }
                group.notify(queue: queue) { [self] in
                    latestFrame = nil; latestCameraFrame = nil
                    if let reportedFailure { continuation.resume(throwing: RecordingError.message(reportedFailure)) }
                    else if index == 0 { continuation.resume(throwing: RecordingError.message(String(localized: "没有收到有效画面。"))) }
                    else { continuation.resume() }
                }
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { fail(error.localizedDescription) }
    }
    private func fail(_ message: String) {
        guard reportedFailure == nil else { return }
        reportedFailure = message
        onFailure(message)
    }

    static func retime(_ buffer: CMSampleBuffer, to time: CMTime, frameRate: Double = 30) throws -> CMSampleBuffer {
        let rate = Int32(max(24, min(120, frameRate.isFinite ? frameRate : 30)).rounded())
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &result)
        guard status == noErr, let result else { throw RecordingError.message(String(localized: "视频时间戳转换失败。")) }
        return result
    }
}

/// 编码完成回调可来自不同队列，只在这个小型容器中使用锁汇总错误。
private final class SegmentErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var first: String? { lock.lock(); defer { lock.unlock() }; return values.first }
}

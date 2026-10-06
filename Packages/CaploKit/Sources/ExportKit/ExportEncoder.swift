@preconcurrency import AVFoundation
import CoreVideo
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox
import ProjectKit
import RenderKit

/// 导出编码：`AVAssetReader` 按视频合成逐帧取出画面、按混音取出声音，`AVAssetWriter` 按导出设置编码。
///
/// 不再用 `AVAssetExportSession` 的"最高质量"预设：它自己决定码率与帧率。实测（2026-10-06，一段 60 fps 的窗口录制）
/// 1080p 只给约 9.4 Mbps；4K 给约 9.9 Mbps，和 1080p 几乎一样，还被降到 30 fps——屏幕录制的文字一动、一推近就糊。
/// 现在格式、码率（按每像素每帧比特数）、帧率、声音都由 `ExportSettings` 决定；GIF 另走 ImageIO。
public enum ExportEncoder {
    /// 编码到 `destination`（调用方负责临时文件与原子替换）。取消外层任务会停掉读写并抛出 `CancellationError`。
    /// 入口在主线程（与 `ProjectMedia` 一致）只做准备；逐帧搬运在读写泵自己的队列上，不占主线程。
    /// 输出尺寸与帧率取自视频合成（调用方按设置建好）。
    @MainActor
    static func encode(asset: AVAsset, videoComposition: AVVideoComposition?, audioMix: AVAudioMix?, destination: URL,
                       settings: ExportSettings, progress: @escaping @Sendable (Double) -> Void) async throws {
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = settings.format.hasAudio && settings.includesAudio ? try await asset.loadTracks(withMediaType: .audio) : []
        guard !videoTracks.isEmpty else { throw ProjectError.invalid("当前工程没有画面，无法导出。") }
        // 没有编辑数据时（只拼接原始片段）也走视频合成：多段素材按时间顺序合成一路画面。
        let composition: AVVideoComposition
        if let videoComposition { composition = videoComposition }
        else {
            let base = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
            // GIF 的帧率远低于录制：没有编辑数据时也要按 GIF 帧率出帧，否则把 60 帧全写进动图。
            if settings.format == .gif, let mutable = base.mutableCopy() as? AVMutableVideoComposition {
                mutable.frameDuration = CMTime(value: 1, timescale: Int32(settings.gifFrameRate))
                composition = mutable
            } else { composition = base }
        }
        let size = composition.renderSize
        let frameRate = composition.frameDuration.seconds > 0 ? 1 / composition.frameDuration.seconds : 30

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        ])
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ProjectError.invalid("无法读取合成画面。") }
        reader.add(videoOutput)

        if settings.format == .gif {
            let writer = GIFWriter(reader: reader, output: videoOutput, destination: destination,
                                   frames: max(1, Int((duration.seconds * frameRate - 0.001).rounded(.up))),
                                   frameRate: frameRate, duration: duration.seconds, progress: progress)
            try await withTaskCancellationHandler { try await writer.run() } onCancel: { writer.cancel() }
            try Task.checkCancellation()
            return
        }

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            output.audioMix = audioMix
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ProjectError.invalid("无法读取混音。") }
            reader.add(output)
            audioOutput = output
        }

        let writer = try AVAssetWriter(outputURL: destination, fileType: settings.format == .proRes ? .mov : .mp4)
        writer.shouldOptimizeForNetworkUse = settings.format != .proRes
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(settings, width: width, height: height, frameRate: frameRate))
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ProjectError.invalid("无法建立视频编码。") }
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            // ProRes 交给后期软件：声音写 24 位 PCM，不再有损压一遍。
            let audioSettings: [String: Any] = settings.format == .proRes
                ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24,
                   AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
                : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: settings.audioBitRate]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ProjectError.invalid("无法建立声音编码。") }
            writer.add(input)
            audioInput = input
        }

        let pump = Pump(reader: reader, writer: writer, video: (videoOutput, videoInput),
                        audio: audioOutput.flatMap { output in audioInput.map { (output, $0) } },
                        duration: duration.seconds, progress: progress)
        try await withTaskCancellationHandler {
            try await pump.run()
        } onCancel: {
            pump.cancel()
        }
        try Task.checkCancellation()
    }

    /// 各格式的视频编码参数。色彩一律标 BT.709（与合成器的输出空间一致，见 `SceneColor`）。
    static func videoSettings(_ settings: ExportSettings, width: Int, height: Int, frameRate: Double) -> [String: Any] {
        let color: [String: Any] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        var result: [String: Any] = [AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoColorPropertiesKey: color]
        switch settings.format {
        case .proRes:
            // ProRes 是固定档位的帧内编码，不接受码率与关键帧参数。
            result[AVVideoCodecKey] = AVVideoCodecType.proRes422
        case .h264, .hevc, .gif:
            let hevc = settings.format == .hevc
            result[AVVideoCodecKey] = hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264
            var compression: [String: Any] = [
                AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
                AVVideoMaxKeyFrameIntervalKey: Int((frameRate * 2).rounded()),
                AVVideoAllowFrameReorderingKey: true,
            ]
            if let bitRate = settings.videoBitRate(width: width, height: height, frameRate: frameRate) { compression[AVVideoAverageBitRateKey] = bitRate }
            compression[AVVideoProfileLevelKey] = hevc ? (kVTProfileLevel_HEVC_Main_AutoLevel as String) : AVVideoProfileLevelH264HighAutoLevel
            result[AVVideoCompressionPropertiesKey] = compression
        }
        return result
    }
}

/// GIF：按合成的帧率（就是 GIF 帧率）逐帧取画面，转成 sRGB 位图写进 ImageIO，无限循环。
/// 合成器输出的是 CoreMedia 709 空间的像素，这里按它解读再落到 sRGB，GIF 的颜色才和视频一致。
private final class GIFWriter: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderOutput
    private let destination: URL
    private let frames: Int
    private let delay: Double
    private let duration: Double
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var cancelled = false

    init(reader: AVAssetReader, output: AVAssetReaderOutput, destination: URL, frames: Int, frameRate: Double, duration: Double,
         progress: @escaping @Sendable (Double) -> Void) {
        self.reader = reader; self.output = output; self.destination = destination; self.frames = frames
        self.delay = 1 / max(1, frameRate); self.duration = max(0.001, duration); self.progress = progress
    }

    func cancel() {
        lock.withLock { cancelled = true }
        reader.cancelReading()
    }
    private var isCancelled: Bool { lock.withLock { cancelled } }

    func run() async throws {
        if isCancelled { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue(label: "com.caplo.export.gif", qos: .userInitiated).async { [self] in
                do { try write(); continuation.resume() } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func write() throws {
        guard reader.startReading() else { throw reader.error ?? ProjectError.invalid("无法开始读取工程素材。") }
        guard let file = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            reader.cancelReading(); throw ProjectError.invalid("无法写入 GIF。")
        }
        CGImageDestinationSetProperties(file, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        let context = CIContext(options: [.cacheIntermediates: false])
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        var written = 0, last: CGImage?
        while written < frames {
            if isCancelled { throw CancellationError() }
            let image: CGImage? = autoreleasepool {
                guard let sample = output.copyNextSampleBuffer(), let buffer = sample.imageBuffer else { return nil }
                let picture = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: SceneColor.output])
                return context.createCGImage(picture, from: picture.extent, format: .RGBA8, colorSpace: sRGB)
            }
            // 读完了但帧数还没到（时长取整的最后一帧）：重复最后一帧补齐，ImageIO 要求帧数与声明一致。
            guard let frame = image ?? last else { break }
            CGImageDestinationAddImage(file, frame, frameProperties)
            last = frame; written += 1
            if written % 5 == 0 { progress(min(0.99, Double(written) / Double(frames))) }
        }
        if isCancelled { throw CancellationError() }
        if reader.status == .failed { throw reader.error ?? ProjectError.invalid("读取工程素材失败。") }
        guard written > 0, CGImageDestinationFinalize(file) else { throw ProjectError.invalid("GIF 写入失败。") }
        progress(1)
    }
}

/// 读写泵：画面与声音各一个串行队列，各自在编码器要数据时搬运，两路都搬完再收尾。
/// AVFoundation 的读写对象不是 Sendable，只在这几个队列上访问；状态用锁保护。
///
/// 等待不能只靠"两路各自收尾"：取消（`cancelWriting`）或写入失败后编码器不会再要数据，
/// `requestMediaDataWhenReady` 的回调可能再也不触发，等两路收尾就会永远卡住——界面上表现为点"取消"没反应。
/// 所以取消与失败直接放行等待，正常读完才逐路计数。
private final class Pump: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let video: (output: AVAssetReaderOutput, input: AVAssetWriterInput)
    private let audio: (output: AVAssetReaderOutput, input: AVAssetWriterInput)?
    private let duration: Double
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var appendFailed = false
    private var remainingLegs = 0
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var reported = -1.0

    init(reader: AVAssetReader, writer: AVAssetWriter, video: (AVAssetReaderOutput, AVAssetWriterInput),
         audio: (AVAssetReaderOutput, AVAssetWriterInput)?, duration: Double, progress: @escaping @Sendable (Double) -> Void) {
        self.reader = reader; self.writer = writer; self.video = video; self.audio = audio
        self.duration = max(0.001, duration); self.progress = progress
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        reader.cancelReading()
        writer.cancelWriting()
        finish()
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func run() async throws {
        if isCancelled { throw CancellationError() }
        guard reader.startReading() else { throw reader.error ?? ProjectError.invalid("无法开始读取工程素材。") }
        guard writer.startWriting() else { reader.cancelReading(); throw writer.error ?? ProjectError.invalid("无法开始写入导出文件。") }
        writer.startSession(atSourceTime: .zero)
        lock.withLock { remainingLegs = audio == nil ? 1 : 2 }
        transfer(audio: false, on: DispatchQueue(label: "com.caplo.export.video"))
        if audio != nil { transfer(audio: true, on: DispatchQueue(label: "com.caplo.export.audio")) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let already = lock.withLock { () -> Bool in
                if finished { return true }
                waiter = continuation
                return false
            }
            if already { continuation.resume() }
        }
        if isCancelled { throw CancellationError() }
        let failedAppend = lock.withLock { appendFailed }
        if reader.status == .failed || failedAppend || writer.status == .failed {
            reader.cancelReading(); writer.cancelWriting()
            throw writer.error ?? reader.error ?? ProjectError.invalid("导出文件写入失败。")
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? ProjectError.invalid("导出文件写入失败。") }
        progress(1)
    }

    /// 放行等待，只放一次。
    private func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let waiter = self.waiter; self.waiter = nil
        lock.unlock()
        waiter?.resume()
    }

    /// 编码器准备好就搬一批；读完、取消或出错时结束这一路。画面这一路顺带报进度。
    /// 读写对象经 `self` 取用而不直接捕获进回调：它们不是 Sendable，由泵统一担保只在各自队列上访问。
    private func transfer(audio isAudio: Bool, on queue: DispatchQueue) {
        let ended = OSAllocatedFlag()
        let leg = isAudio ? audio! : video
        leg.input.requestMediaDataWhenReady(on: queue) { [self] in
            let (output, input) = isAudio ? audio! : video
            // 编码器暂时满了就退出，等下一次回调接着搬；读完、取消、出错才收尾这一路。
            var done = false, failed = false
            while input.isReadyForMoreMediaData {
                if isCancelled || writer.status == .failed { done = true; failed = writer.status == .failed; break }
                guard let sample = output.copyNextSampleBuffer() else { done = true; break }
                if !isAudio { report(sample.presentationTimeStamp.seconds) }
                if !input.append(sample) { done = true; failed = true; break }
            }
            guard done, ended.set() else { return }
            if isCancelled { finish(); return }
            if failed {
                // 写入失败：另一路可能永远等不到回调，直接放行，由 run() 统一报错。
                lock.lock(); appendFailed = true; lock.unlock()
                finish(); return
            }
            input.markAsFinished()
            lock.lock(); remainingLegs -= 1; let last = remainingLegs <= 0; lock.unlock()
            if last { finish() }
        }
    }

    private func report(_ seconds: Double) {
        let value = min(0.99, max(0, seconds / duration))
        guard value - reported >= 0.005 else { return }
        reported = value
        progress(value)
    }
}

/// 只置位一次的标志：搬运回调可能在"读完"之后又被调用一次，收尾只能做一次。
private final class OSAllocatedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    /// 第一次调用返回 true。
    func set() -> Bool { lock.lock(); defer { lock.unlock() }; if value { return false }; value = true; return true }
}

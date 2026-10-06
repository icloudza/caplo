import AVFoundation
import Foundation
import Testing
import EditingCore
import ProjectKit
import ExportKit

/// 写一段最简单的画面素材；片段索引要求每段都有 screen 文件。
@MainActor
private func writeScreen(_ url: URL, path: String, duration: Double) async throws {
    let writer = try AVAssetWriter(outputURL: url.appendingPathComponent(path), fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90,
    ])
    writer.add(input)
    #expect(writer.startWriting()); writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    let pool = try #require(adaptor.pixelBufferPool)
    #expect(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess)
    let pixel = try #require(buffer)
    #expect(adaptor.append(pixel, withPresentationTime: .zero))
    writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
    input.markAsFinished()
    await writer.finishWriting()
}

/// 逐段转写的结果要按各段起点平移后拼起来，顺序按源时间排。
@Test @MainActor func transcriptionShiftsEachSegmentOntoTheSourceTimeline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "分段拼接")
    for (number, duration) in [2.0, 3.0].enumerated() {
        let path = "Media/\(String(format: "%06d", number))-microphone.caf"
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(48_000 * duration)))
        buffer.frameLength = buffer.frameCapacity
        let file = try AVAudioFile(forWriting: url.appendingPathComponent(path), settings: format.settings)
        try file.write(from: buffer)
        let screenPath = "Media/\(String(format: "%06d", number))-screen.mov"
        try await writeScreen(url, path: screenPath, duration: duration)
        try ProjectStorage.commit(SegmentRecord(id: number, duration: duration, files: [.microphone: path, .screen: screenPath]), to: url)
    }
    try ProjectStorage.complete(url)
    let document = try ProjectStorage.load(url)

    // 假引擎：每段都在自己的 0.5…1.5 秒返回一句，好检验平移。
    struct StubEngine: TranscriptionEngine {
        var name: String { "测试" }
        func availability(locale: Locale) async -> TranscriptionAvailability { .ready }
        func transcribe(file: URL, locale: Locale, progress: @Sendable @escaping (Double) -> Void) async throws -> [CaptionCue] {
            progress(1)
            return [CaptionCue(sourceStart: 0.5, sourceEnd: 1.5, text: "一句话",
                               words: [CaptionWord(start: 0.5, end: 1.5, text: "一句话")])]
        }
    }
    let seen = ProgressLog()
    let cues = try await ProjectTranscription.run(url: url, document: document, source: .microphone,
                                                  locale: Locale(identifier: "zh-CN"), engine: StubEngine()) { seen.record($0) }
    let starts = cues.map { $0.sourceStart }
    #expect(starts == [0.5, 2.5], "两段的句子落在 \(starts)")
    #expect(cues[1].words?.first?.start == 2.5, "词表没跟着段一起平移")
    let values = seen.values
    #expect(values.last == 1 && values.allSatisfy { $0 >= 0 && $0 <= 1 })
}

/// 进度回调跨并发边界，测试里用它收集。
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func record(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}


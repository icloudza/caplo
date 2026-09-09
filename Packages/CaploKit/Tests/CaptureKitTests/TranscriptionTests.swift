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

/// 转写最容易踩、也最难查的坑是时间轴：字幕的源时间必须和指针事件用**完全相同**的游标口径累加。
/// 差一点点，整条字幕就会系统性偏移，而且越到后面偏得越多。这里把两条时间轴钉死。
@Test @MainActor func transcriptionSharesTheEventTimeAxis() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "时间轴对齐")

    // 三段录制：3 秒、4 秒、5 秒。第二段的麦克风比画面晚 0.25 秒才开始。
    let durations = [3.0, 4.0, 5.0]
    for (number, duration) in durations.enumerated() {
        let audioPath = "Media/\(String(format: "%06d", number))-microphone.caf"
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let frames = AVAudioFrameCount(48_000 * duration)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let file = try AVAudioFile(forWriting: url.appendingPathComponent(audioPath), settings: format.settings)
        try file.write(from: buffer)

        let eventsPath = "Events/\(String(format: "%06d", number)).json"
        // 每段都在自己的第 1 秒放一个事件；它们在源时间轴上应当落在 1、4、8 秒。
        let sample = PointerSample(time: 1, x: 0.5, y: 0.5, kind: .move)
        try JSONEncoder().encode([sample]).write(to: url.appendingPathComponent(eventsPath))

        let screenPath = "Media/\(String(format: "%06d", number))-screen.mov"
        try await writeScreen(url, path: screenPath, duration: duration)
        var record = SegmentRecord(id: number, duration: duration, files: [.microphone: audioPath, .screen: screenPath])
        record.eventsPath = eventsPath
        if number == 1 { record.mediaOffsets = [.microphone: 0.25] }
        try ProjectStorage.commit(record, to: url)
    }
    try ProjectStorage.complete(url)
    let document = try ProjectStorage.load(url)

    let events = try EditStorage.events(in: url, document: document)
    #expect(events.map(\.time) == [1, 4, 8], "事件时间轴变成了 \(events.map(\.time))")

    let origins = ProjectTranscription.segmentOrigins(document, source: .microphone)
    #expect(origins.map(\.origin) == [0, 3.25, 7], "转写的段起点是 \(origins.map(\.origin))")
    // 除了各素材自己的偏移，两条轴必须一模一样：第二段没有偏移时它的起点就是事件那边的 3。
    #expect(origins[0].origin == 0 && origins[2].origin == 7)
    #expect(ProjectTranscription.hasAudio(document, source: .microphone))
    #expect(!ProjectTranscription.hasAudio(document, source: .system))
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

/// 断句：遇到句末标点、停顿超过 0.6 秒、或者一句太长就断开。
@Test func sentenceSegmentationBreaksOnPunctuationPausesAndLength() {
    func word(_ text: String, _ start: Double, _ duration: Double = 0.3) -> RecognizedWord {
        RecognizedWord(text: text, start: start, duration: duration)
    }
    // 句末标点断句。
    let punctuated = SpeechTranscriber.sentences(from: [
        word("把留白", 0), word("调到四十。", 0.3), word("然后", 0.7), word("看看效果。", 1.0),
    ])
    #expect(punctuated.map { $0.text } == ["把留白调到四十。", "然后看看效果。"])
    #expect(punctuated[0].sourceStart == 0 && abs(punctuated[0].sourceEnd - 0.6) < 0.001)

    // 长停顿断句：中间隔了 1.2 秒。
    let paused = SpeechTranscriber.sentences(from: [word("前半句", 0), word("后半句", 1.5)])
    #expect(paused.count == 2, "停顿没有断句，得到 \(paused.map { $0.text })")

    // 英文词之间要补空格，中文不补。
    let english = SpeechTranscriber.sentences(from: [word("npm", 0), word("run", 0.3), word("build.", 0.6)])
    #expect(english.map { $0.text } == ["npm run build."])

    // 一句实在太长又没有任何标点，也要断，不然字幕铺满整屏。
    let long = (0..<30).map { word("字字", Double($0) * 0.3) }
    let broken = SpeechTranscriber.sentences(from: long)
    #expect(broken.count > 1, "超长句没有断开")
    let limit = SpeechTranscriber.maximumCharacters * 2 + 2
    let withinLimit = broken.allSatisfy { $0.text.count <= limit }
    #expect(withinLimit)
    // 每一句的词表都要落在它自己的时间范围里。
    for cue in broken {
        let lower = cue.sourceStart - 0.001, upper = cue.sourceEnd + 0.001
        let inside = (cue.words ?? []).allSatisfy { $0.start >= lower && $0.end <= upper }
        #expect(inside)
    }
}

/// 空结果、纯空白不该产生空句子。
@Test func sentenceSegmentationIgnoresBlanks() {
    #expect(SpeechTranscriber.sentences(from: []).isEmpty)
    #expect(SpeechTranscriber.sentences(from: [RecognizedWord(text: "   ", start: 0, duration: 0.2)]).isEmpty)
}

/// 进度回调跨并发边界，测试里用它收集。
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func record(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// 音频文件常常比它那一段的标称时长长一点，转写出来的最后一句会越过工程总长。
/// 不夹住就会在校验时被整批拒掉，用户看到"编辑数据版本不支持或内容无效"，一次转写白跑。
@Test @MainActor func transcriptionClampsCuesToTheProjectDuration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "越界夹住")
    let path = "Media/000000-microphone.caf"
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(48_000 * 3)))
    buffer.frameLength = buffer.frameCapacity
    let file = try AVAudioFile(forWriting: url.appendingPathComponent(path), settings: format.settings)
    try file.write(from: buffer)
    let screenPath = "Media/000000-screen.mov"
    try await writeScreen(url, path: screenPath, duration: 2)
    // 段标称 2 秒，音频却有 3 秒。
    try ProjectStorage.commit(SegmentRecord(id: 0, duration: 2, files: [.microphone: path, .screen: screenPath]), to: url)
    try ProjectStorage.complete(url)
    let document = try ProjectStorage.load(url)
    #expect(document.duration == 2)

    struct OverrunEngine: TranscriptionEngine {
        var name: String { "越界测试" }
        func availability(locale: Locale) async -> TranscriptionAvailability { .ready }
        func transcribe(file: URL, locale: Locale, progress: @Sendable @escaping (Double) -> Void) async throws -> [CaptionCue] {
            progress(1)
            return [
                CaptionCue(sourceStart: 0.2, sourceEnd: 1.0, text: "范围内",
                           words: [CaptionWord(start: 0.2, end: 1.0, text: "范围内")]),
                CaptionCue(sourceStart: 1.5, sourceEnd: 2.6, text: "跨过边界",
                           words: [CaptionWord(start: 1.5, end: 2.6, text: "跨过边界")]),
                CaptionCue(sourceStart: 2.4, sourceEnd: 3.0, text: "完全在外面", words: nil),
            ]
        }
    }
    let cues = try await ProjectTranscription.run(url: url, document: document, source: .microphone,
                                                  locale: Locale(identifier: "zh-CN"), engine: OverrunEngine()) { _ in }
    #expect(cues.map { $0.text } == ["范围内", "跨过边界"], "得到 \(cues.map { $0.text })")
    #expect(cues[1].sourceEnd == 2, "跨界那句没被夹住，结束在 \(cues[1].sourceEnd)")
    #expect(cues[1].words?.last?.end == 2, "词表没跟着夹")

    // 直接喂给工程也必须过校验。
    var edit = VideoEdit(duration: document.duration)
    edit.captionList = cues
    try edit.validate(sourceDuration: document.duration)
}

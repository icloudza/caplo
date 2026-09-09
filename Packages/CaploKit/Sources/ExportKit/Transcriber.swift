@preconcurrency import AVFoundation
import Foundation
import Speech
import EditingCore
import ProjectKit

/// 转写引擎。换引擎（比如以后接 WhisperKit）只要再实现一遍这个协议，
/// 上层的字幕数据、投影、面板与导出一行都不用改。
public protocol TranscriptionEngine: Sendable {
    var name: String { get }
    /// 这台机器上能不能用（语言包装没装、系统不支持等）。
    func availability(locale: Locale) async -> TranscriptionAvailability
    /// 把一个音频文件转写成句子，时间相对该文件的零时刻。
    func transcribe(file: URL, locale: Locale, progress: @Sendable @escaping (Double) -> Void) async throws -> [CaptionCue]
}

public enum TranscriptionAvailability: Equatable, Sendable {
    case ready
    /// 还没授权；调用方应当先请求。
    case needsPermission
    case unavailable(String)
}

public enum TranscriptionError: LocalizedError {
    case denied
    case unsupported(String)
    case noAudio
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .denied: "没有语音识别权限。请在「系统设置 › 隐私与安全性 › 语音识别」里允许 Caplo。"
        case .unsupported(let reason): reason
        case .noAudio: "这个工程里没有可转写的声音轨。"
        case .failed(let reason): "转写失败：\(reason)"
        }
    }
}

/// 转写用哪条声音。
public enum TranscriptionSource: String, CaseIterable, Sendable, Identifiable {
    case microphone, system
    public var id: String { rawValue }
    public var title: String { self == .microphone ? "麦克风" : "系统声音" }
    var role: MediaRole { self == .microphone ? .microphone : .systemAudio }
}

/// 整个工程的转写。
///
/// 时间轴对齐是这里最要命的一件事：转写出来的时间必须和 `EditStorage.events` 用**完全相同**的游标口径
/// 累加，否则整条字幕会系统性偏移，而且越往后偏得越多。所以这里逐段转写、逐段按
/// `cursor + segment.offset(for:)` 平移，和事件那边一字不差。
public enum ProjectTranscription {
    /// 每段音频在源时间轴上的零点。事件与字幕共用这一个口径。
    public static func segmentOrigins(_ document: ProjectDocument, source: TranscriptionSource) -> [(path: String, origin: Double)] {
        var result: [(String, Double)] = []
        var cursor = 0.0
        for segment in document.segments.sorted(by: { $0.id < $1.id }) {
            defer { cursor += segment.duration }
            guard let path = segment.files[source.role] else { continue }
            result.append((path, cursor + segment.offset(for: source.role)))
        }
        return result
    }

    /// 工程里有没有这条声音。
    public static func hasAudio(_ document: ProjectDocument, source: TranscriptionSource) -> Bool {
        document.segments.contains { $0.files[source.role] != nil }
    }

    public static func run(url: URL, document: ProjectDocument, source: TranscriptionSource, locale: Locale,
                           engine: any TranscriptionEngine, progress: @Sendable @escaping (Double) -> Void) async throws -> [CaptionCue] {
        let origins = segmentOrigins(document, source: source)
        guard !origins.isEmpty else { throw TranscriptionError.noAudio }
        // 音频文件常常比它那一段的标称时长长出零点几秒（编码器补的尾巴、mediaOffsets 的取整）。
        // 不夹住的话最后一句会越过工程总长，整批结果在校验时被拒，用户看到的是
        // "编辑数据版本不支持或内容无效"——一次转写白跑。
        let limit = document.duration
        guard limit > 0 else { throw TranscriptionError.noAudio }
        var result: [CaptionCue] = []
        for (number, entry) in origins.enumerated() {
            let file = try ProjectStorage.mediaURL(entry.path, in: url)
            let share = 1.0 / Double(origins.count)
            let cues = try await engine.transcribe(file: file, locale: locale) { value in
                progress(min(1, Double(number) * share + value * share))
            }
            for var cue in cues {
                cue.sourceStart += entry.origin
                cue.sourceEnd += entry.origin
                cue.words = cue.words?.map { CaptionWord(start: $0.start + entry.origin, end: $0.end + entry.origin, text: $0.text) }
                guard let clamped = clamp(cue, to: limit) else { continue }
                result.append(clamped)
            }
        }
        progress(1)
        return result.sorted { $0.sourceStart < $1.sourceStart }
    }

    /// 把一句夹进 0…limit。整句都在范围外就丢掉；词表跟着一起夹，免得高亮指向不存在的时间。
    static func clamp(_ cue: CaptionCue, to limit: Double) -> CaptionCue? {
        guard cue.sourceStart.isFinite, cue.sourceEnd.isFinite else { return nil }
        let start = max(0, min(cue.sourceStart, limit)), end = max(0, min(cue.sourceEnd, limit))
        guard end - start > 0.02 else { return nil }
        var result = cue
        result.sourceStart = start; result.sourceEnd = end
        result.words = cue.words?.compactMap { word in
            let lower = max(start, min(word.start, end)), upper = max(start, min(word.end, end))
            guard upper >= lower else { return nil }
            return CaptionWord(start: lower, end: upper, text: word.text)
        }
        if result.words?.isEmpty == true { result.words = nil }
        return result
    }
}

/// 系统自带的本机语音识别。不下载模型、不上传音频，代价是中文的词级时间戳比较粗，
/// 面板里的「按字均分」默认打开就是为了兜这个。
public struct SpeechTranscriber: TranscriptionEngine {
    /// 一句最多这么多字；再长就在标点或停顿处断开。
    public static let maximumCharacters = 22
    /// 停顿超过这么久就断句。
    public static let sentenceGap = 0.6
    /// 断句用的句末标点。
    static let terminators: Set<Character> = ["。", "！", "？", "…", ".", "!", "?", "；", ";"]
    /// 断句用的句中标点：超长时才在这里断。
    static let separators: Set<Character> = ["，", "、", ",", "：", ":"]

    public init() {}
    public var name: String { "系统本机识别" }

    public func availability(locale: Locale) async -> TranscriptionAvailability {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return .unavailable("系统不支持这个语言的本机识别。")
        }
        guard recognizer.isAvailable else { return .unavailable("语音识别当前不可用，请稍后再试。") }
        guard recognizer.supportsOnDeviceRecognition else {
            return .unavailable("这个语言还没有本机识别模型。请在「系统设置 › 键盘 › 听写」里添加该语言后重试。")
        }
        return switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .ready
        case .notDetermined: .needsPermission
        default: .unavailable(TranscriptionError.denied.localizedDescription)
        }
    }

    /// 请求权限；已授权直接返回真。
    public static func requestPermission() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    public func transcribe(file: URL, locale: Locale, progress: @Sendable @escaping (Double) -> Void) async throws -> [CaptionCue] {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.unsupported("这个语言还没有本机识别模型。")
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw TranscriptionError.denied }
        let request = SFSpeechURLRecognitionRequest(url: file)
        // 音频绝不离开这台电脑；这一行是整个功能对用户的承诺。
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        let duration = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? 0

        let segments: [RecognizedWord] = try await withCheckedThrowingContinuation { continuation in
            let box = ResultBox(continuation: continuation)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error { box.fail(TranscriptionError.failed(error.localizedDescription)); return }
                guard let result else { return }
                // 识别结果的类型不是 Sendable，先在这里抄成纯值再跨越并发边界。
                if result.isFinal {
                    box.finish(result.bestTranscription.segments.map {
                        RecognizedWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                    })
                }
                else if duration > 0, let last = result.bestTranscription.segments.last {
                    progress(min(0.99, (last.timestamp + last.duration) / duration))
                }
            }
            box.attach(task)
        }
        progress(1)
        return Self.sentences(from: segments)
    }

    /// 把识别出的一串词拼成句子：遇到句末标点、停顿过久或超长就断开。
    public static func sentences(from segments: [RecognizedWord]) -> [CaptionCue] {
        var result: [CaptionCue] = []
        var words: [CaptionWord] = []
        var text = ""
        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { words = []; text = "" }
            guard !trimmed.isEmpty, let first = words.first, let last = words.last else { return }
            var cue = CaptionCue(sourceStart: first.start, sourceEnd: max(first.start + 0.2, last.end),
                                 text: String(trimmed.prefix(CaptionCue.textLimit)), words: words)
            cue.locked = false
            result.append(cue)
        }
        for segment in segments {
            let piece = segment.text
            guard !piece.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            // 与上一个词之间停顿太久：先断句，再开始新的一句。
            if let last = words.last, segment.start - last.end > sentenceGap { flush() }
            words.append(CaptionWord(start: segment.start, end: segment.start + segment.duration, text: piece))
            // 中文没有词间空格；英文词之间补一个，拼出来才读得通。
            if !text.isEmpty, piece.first?.isASCII == true, text.last?.isASCII == true { text += " " }
            text += piece
            if let terminator = piece.last, terminators.contains(terminator) { flush(); continue }
            if text.count >= maximumCharacters, let separator = piece.last, separators.contains(separator) { flush(); continue }
            // 实在太长又没有任何标点，也要断，不然一句字幕铺满整屏。
            if text.count >= maximumCharacters * 2 { flush() }
        }
        flush()
        return result
    }
}

/// 识别出的一个词。系统的结果类型不是 Sendable，先抄成这个再跨并发边界。
public struct RecognizedWord: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var duration: Double
    public init(text: String, start: Double, duration: Double) {
        self.text = text; self.start = start; self.duration = duration
    }
}

/// 识别回调可能被调用多次；这个盒子保证 continuation 只被恢复一次，并在失败时取消任务。
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[RecognizedWord], any Error>?
    private var task: SFSpeechRecognitionTask?

    init(continuation: CheckedContinuation<[RecognizedWord], any Error>) { self.continuation = continuation }

    func attach(_ task: SFSpeechRecognitionTask?) {
        lock.lock(); defer { lock.unlock() }
        // continuation 已经恢复过就说明任务早就结束了，这里直接取消。
        if self.continuation == nil { task?.cancel() } else { self.task = task }
    }
    func finish(_ segments: [RecognizedWord]) {
        lock.lock(); let pending = continuation; continuation = nil; task = nil; lock.unlock()
        pending?.resume(returning: segments)
    }
    func fail(_ error: any Error) {
        lock.lock(); let pending = continuation; continuation = nil; let running = task; task = nil; lock.unlock()
        running?.cancel()
        pending?.resume(throwing: error)
    }
}

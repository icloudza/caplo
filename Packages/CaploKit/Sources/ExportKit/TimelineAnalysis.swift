@preconcurrency import AVFoundation
import Accelerate
import ProjectKit

/// 时间线的音频代理数据：按工程时间（各片段顺序拼接，并计入音轨相对片段的起始偏移）每 10 毫秒一个峰值，
/// 另备逐级 8 倍粗化的金字塔，任意时间区间的峰值都能在十几次比较内取到，缩得再小也不会漏掉短促的声音。
/// 缩略图改由 `ThumbnailGenerator` 按需生成，不再在打开时批量抽帧。
public struct TimelineAnalysis: Sendable {
    /// 每秒峰值格数：一格 10 毫秒，最高缩放（每秒 960 点）下约 10 点一格。
    public static let binsPerSecond = 100.0
    static let levelFactor = 8

    /// 10 毫秒一格的峰值（0…1），按工程时间索引；缺失音轨为空数组。
    public let system: [Float]
    public let microphone: [Float]
    private let systemLevels: [[Float]]
    private let microphoneLevels: [[Float]]

    public init(system: [Float] = [], microphone: [Float] = []) {
        self.system = system; self.microphone = microphone
        systemLevels = Self.levels(for: system); microphoneLevels = Self.levels(for: microphone)
    }

    /// 工程时间 `start…end` 内的峰值（0…1）；没有音轨返回 0。
    public func systemPeak(from start: Double, to end: Double) -> Float { Self.peak(in: systemLevels, from: start, to: end) }
    public func microphonePeak(from start: Double, to end: Double) -> Float { Self.peak(in: microphoneLevels, from: start, to: end) }

    /// 后台生成波形代理数据：实际 PCM 峰值，缺失音轨保留空数组，不使用装饰性假波形。
    public static func load(url: URL, document: ProjectDocument) async throws -> TimelineAnalysis {
        let worker = Task.detached(priority: .utility) {
            let bins = Int((document.duration * binsPerSecond).rounded(.up))
            guard bins > 0 else { return TimelineAnalysis() }
            var system = [Float](repeating: 0, count: bins), microphone = system
            var hasSystem = false, hasMicrophone = false
            var cursor = 0.0
            for segment in document.segments.sorted(by: { $0.id < $1.id }) {
                defer { cursor += segment.duration }
                try Task.checkCancellation()
                for role in [MediaRole.systemAudio, .microphone] {
                    guard let path = segment.files[role] else { continue }
                    let asset = AVURLAsset(url: try ProjectStorage.mediaURL(path, in: url))
                    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                    let reader = try AVAssetReader(asset: asset)
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
                    reader.add(output)
                    guard reader.startReading() else { throw reader.error ?? ProjectError.invalid("无法读取音频波形。") }
                    defer { reader.cancelReading() }
                    // 音轨可能晚于画面开始（`mediaOffsets`），格子按片段时间对齐，和合成、导出用同一条规则。
                    let segmentStart = cursor + segment.offset(for: role)
                    while let sample = output.copyNextSampleBuffer() {
                        try Task.checkCancellation()
                        guard let data = sample.dataBuffer, let format = sample.formatDescription,
                              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                              sample.presentationTimeStamp.isNumeric else { continue }
                        let channels = Int(max(1, description.mChannelsPerFrame))
                        let sampleRate = description.mSampleRate > 0 ? description.mSampleRate : 48_000
                        let frames = CMBlockBufferGetDataLength(data) / (MemoryLayout<Float>.size * channels)
                        guard frames > 0 else { continue }
                        let base = segmentStart + sample.presentationTimeStamp.seconds
                        try withContiguousFloats(of: data, count: frames * channels) { samples in
                            if role == .systemAudio { accumulate(into: &system, samples: samples, frames: frames, channels: channels, sampleRate: sampleRate, base: base) }
                            else { accumulate(into: &microphone, samples: samples, frames: frames, channels: channels, sampleRate: sampleRate, base: base) }
                        }
                    }
                    guard reader.status == .completed else { throw reader.error ?? ProjectError.invalid("波形读取中断。") }
                    if role == .systemAudio { hasSystem = true } else { hasMicrophone = true }
                }
            }
            return TimelineAnalysis(system: hasSystem ? system : [], microphone: hasMicrophone ? microphone : [])
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// 连续内存直接借用，不连续或未对齐时才复制一份。
    private static func withContiguousFloats(of data: CMBlockBuffer, count: Int, _ body: (UnsafePointer<Float>) throws -> Void) throws {
        let bytes = count * MemoryLayout<Float>.size
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        if CMBlockBufferGetDataPointer(data, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &pointer) == noErr,
           let pointer, length >= bytes, Int(bitPattern: pointer) % MemoryLayout<Float>.alignment == 0 {
            try pointer.withMemoryRebound(to: Float.self, capacity: count) { try body(UnsafePointer($0)) }
            return
        }
        var copy = [Float](repeating: 0, count: count)
        let status = copy.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
        guard status == noErr else { throw ProjectError.invalid("波形样本无法解码。") }
        try copy.withUnsafeBufferPointer { try body($0.baseAddress!) }
    }

    /// 把一段交错 PCM 的峰值并入格子：`base` 是首帧的工程时间；每格一次 vDSP 求绝对值最大，不逐样本换算。
    static func accumulate(into peaks: inout [Float], samples: UnsafePointer<Float>, frames: Int, channels: Int, sampleRate: Double, base: Double) {
        guard frames > 0, channels > 0, sampleRate > 0, base.isFinite, !peaks.isEmpty else { return }
        let binDuration = 1 / binsPerSecond
        // 工程零时刻之前的样本（偏移为负）跳过。
        var frame = base < 0 ? Int((-base * sampleRate).rounded(.up)) : 0
        while frame < frames {
            let time = base + Double(frame) / sampleRate
            let bin = Int(time * binsPerSecond)
            guard bin < peaks.count else { break }
            let binEnd = Double(bin + 1) * binDuration
            let next = min(frames, max(frame + 1, Int(((binEnd - base) * sampleRate).rounded(.up))))
            var peak: Float = 0
            vDSP_maxmgv(samples + frame * channels, 1, &peak, vDSP_Length((next - frame) * channels))
            if peak.isFinite { peaks[bin] = max(peaks[bin], min(1, peak)) }
            frame = next
        }
    }

    /// 金字塔：每一级把上一级 8 格并成 1 格取最大值，直到只剩不超过 8 格。
    static func levels(for peaks: [Float]) -> [[Float]] {
        guard !peaks.isEmpty else { return [] }
        var levels = [peaks]
        while let last = levels.last, last.count > levelFactor {
            var next = [Float](repeating: 0, count: (last.count + levelFactor - 1) / levelFactor)
            last.withUnsafeBufferPointer { buffer in
                for index in next.indices {
                    let start = index * levelFactor, count = min(levelFactor, last.count - start)
                    var peak: Float = 0
                    vDSP_maxv(buffer.baseAddress! + start, 1, &peak, vDSP_Length(count))
                    next[index] = peak
                }
            }
            levels.append(next)
        }
        return levels
    }

    /// 精确取区间峰值：两端不对齐的零头用细格，中间对齐的整块逐级换成粗格，每级最多看 14 格，
    /// 一小时的时间线也只需约百次比较；结果和逐格扫描完全一致，不会把邻近列的声音抹进来。
    static func peak(in levels: [[Float]], from start: Double, to end: Double) -> Float {
        guard let fine = levels.first, !fine.isEmpty, start.isFinite, end.isFinite, end > start else { return 0 }
        var low = max(0, Int(start * binsPerSecond))
        guard low < fine.count else { return 0 }
        var high = min(fine.count - 1, max(low, Int((end * binsPerSecond).rounded(.up)) - 1))
        var peak: Float = 0
        var level = 0
        while low <= high {
            let bins = levels[level]
            if level + 1 == levels.count {
                for index in low...high { peak = max(peak, bins[index]) }
                break
            }
            while low <= high, low % levelFactor != 0 { peak = max(peak, bins[low]); low += 1 }
            while low <= high, (high + 1) % levelFactor != 0 { peak = max(peak, bins[high]); high -= 1 }
            guard low <= high else { break }
            low /= levelFactor; high = (high + 1) / levelFactor - 1; level += 1
        }
        return peak
    }
}

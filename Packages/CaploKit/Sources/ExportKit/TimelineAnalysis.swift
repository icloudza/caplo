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
    ///
    /// - 每个音频文件的峰值单独算、单独缓存在工程 `Cache/Peaks/` 里（按文件大小与修改时间核对）：
    ///   以前每次打开编辑器都把全部录音重新解码一遍，两小时的工程光系统声音就要读两个多 GB；
    /// - 某个文件读不出来（缺失、损坏）只空出它那一段，不再让整条波形都没有；
    /// - `voiceProcessing` 打开且已有处理产物时，麦克风波形画处理后的声音，和听到的一致。
    public static func load(url: URL, document: ProjectDocument, voiceProcessing: Bool = false) async throws -> TimelineAnalysis {
        let worker = Task.detached(priority: .utility) {
            let bins = Int((document.duration * binsPerSecond).rounded(.up))
            guard bins > 0 else { return TimelineAnalysis() }
            var system = [Float](repeating: 0, count: bins), microphone = system
            var hasSystem = false, hasMicrophone = false
            let cache = url.appendingPathComponent("Cache/Peaks", isDirectory: true)
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            var cursor = 0.0
            for segment in document.segments.sorted(by: { $0.id < $1.id }) {
                defer { cursor += segment.duration }
                try Task.checkCancellation()
                for role in [MediaRole.systemAudio, .microphone] {
                    guard var path = segment.files[role] else { continue }
                    if role == .microphone, voiceProcessing, let processed = VoiceProcessor.processedPath(for: segment), ProjectStorage.mediaExists(processed, in: url) { path = processed }
                    guard ProjectStorage.mediaExists(path, in: url), let file = try? ProjectStorage.mediaURL(path, in: url) else { continue }
                    let peaks: [Float]
                    do { peaks = try await filePeaks(file, cache: cache) }
                    catch is CancellationError { throw CancellationError() }
                    catch { NSLog("Caplo：波形跳过读不出来的音频 %@：%@", path, error.localizedDescription); continue }
                    // 音轨可能晚于画面开始（`mediaOffsets`），格子按片段时间对齐，和合成、导出用同一条规则。
                    let base = cursor + segment.offset(for: role)
                    if role == .systemAudio { merge(peaks, into: &system, base: base); hasSystem = true }
                    else { merge(peaks, into: &microphone, base: base); hasMicrophone = true }
                }
            }
            return TimelineAnalysis(system: hasSystem ? system : [], microphone: hasMicrophone ? microphone : [])
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// 文件级峰值放到工程时间轴上：整体平移 `base` 换算成的格数（四舍五入到最近一格，误差不超过 5 毫秒）。
    /// 不能逐格算 (base + i / 100) × 100 再向下取整：浮点误差会让整段错开一格。
    static func merge(_ peaks: [Float], into timeline: inout [Float], base: Double) {
        let shift = Int((base * binsPerSecond).rounded())
        for (index, value) in peaks.enumerated() where value > 0 {
            let bin = shift + index
            guard bin >= 0 else { continue }
            guard bin < timeline.count else { break }
            timeline[bin] = max(timeline[bin], value)
        }
    }

    /// 缓存文件头：魔数、文件大小、修改时间、格数，后面是格子。
    private static let cacheMagic: UInt32 = 0x314B_5043   // "CPK1"

    /// 一个音频文件的峰值（每 10 毫秒一格，相对文件起点）。缓存命中就直接读，否则解码一遍再写缓存。
    static func filePeaks(_ file: URL, cache: URL) async throws -> [Float] {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = UInt64(values.fileSize ?? 0), modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let cached = cache.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".peaks")
        if let data = try? Data(contentsOf: cached), data.count >= 24 {
            let header = data.withUnsafeBytes { raw in
                (raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self), raw.loadUnaligned(fromByteOffset: 4, as: UInt64.self),
                 raw.loadUnaligned(fromByteOffset: 12, as: Double.self), raw.loadUnaligned(fromByteOffset: 20, as: UInt32.self))
            }
            if header.0 == cacheMagic, header.1 == size, header.2 == modified, data.count == 24 + Int(header.3) * 4 {
                return data.withUnsafeBytes { raw in (0..<Int(header.3)).map { raw.loadUnaligned(fromByteOffset: 24 + $0 * 4, as: Float.self) } }
            }
        }
        let peaks = try await decodePeaks(file)
        var data = Data(capacity: 24 + peaks.count * 4)
        withUnsafeBytes(of: cacheMagic) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: size) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: modified) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(peaks.count)) { data.append(contentsOf: $0) }
        peaks.withUnsafeBytes { data.append(contentsOf: $0) }
        try? data.write(to: cached, options: .atomic)
        return peaks
    }

    /// 解码整个音频文件取峰值。
    static func decodePeaks(_ file: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let duration = try await asset.load(.duration).seconds
        var peaks = [Float](repeating: 0, count: max(1, Int(((duration.isFinite ? duration : 0) * binsPerSecond).rounded(.up)) + 1))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ProjectError.invalid(String(localized: "无法读取音频波形。")) }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let data = sample.dataBuffer, let format = sample.formatDescription,
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  sample.presentationTimeStamp.isNumeric else { continue }
            let channels = Int(max(1, description.mChannelsPerFrame))
            let sampleRate = description.mSampleRate > 0 ? description.mSampleRate : 48_000
            let frames = CMBlockBufferGetDataLength(data) / (MemoryLayout<Float>.size * channels)
            guard frames > 0 else { continue }
            let base = sample.presentationTimeStamp.seconds
            try withContiguousFloats(of: data, count: frames * channels) { samples in
                accumulate(into: &peaks, samples: samples, frames: frames, channels: channels, sampleRate: sampleRate, base: base)
            }
        }
        guard reader.status == .completed else { throw reader.error ?? ProjectError.invalid(String(localized: "波形读取中断。")) }
        return peaks
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
        guard status == noErr else { throw ProjectError.invalid(String(localized: "波形样本无法解码。")) }
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

import Foundation
import AVFoundation
import Testing
import ProjectKit
@testable import ExportKit

/// 波形代理：10 毫秒精度、音轨相对片段的起始偏移对齐、金字塔任意区间峰值。
@Test func waveformPeaksAlignToSegmentOffsetAtTenMillisecondResolution() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "波形精度")
    // 2 秒立体声：0.50–0.75 秒是幅度 0.5 的 1 kHz 正弦，其余静音；音轨相对片段晚 0.30 秒开始。
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
    buffer.frameLength = buffer.frameCapacity
    let channels = try #require(buffer.floatChannelData)
    for channel in 0..<2 {
        for index in 0..<96_000 {
            let time = Double(index) / 48_000
            channels[channel][index] = time >= 0.5 && time < 0.75 ? Float(sin(time * 1000 * 2 * .pi)) * 0.5 : 0
        }
    }
    let path = "Media/system.caf"
    let file = try AVAudioFile(forWriting: url.appendingPathComponent(path), settings: format.settings)
    try file.write(from: buffer)
    var document = try ProjectStorage.load(url)
    var segment = SegmentRecord(id: 0, duration: 2.5, files: [.systemAudio: path])
    segment.mediaOffsets = [.systemAudio: 0.3]
    document.segments = [segment]

    let analysis = try await TimelineAnalysis.load(url: url, document: document)
    #expect(analysis.microphone.isEmpty)
    #expect(analysis.system.count == 250)
    // 声音落在工程时间 0.80–1.05 秒：之前与之后的格子安静，之内的格子接近 0.5（边界两格不计）。
    #expect(analysis.system[0..<79].allSatisfy { $0 < 0.001 })
    #expect(analysis.system[81..<104].allSatisfy { $0 > 0.4 && $0 <= 0.51 })
    #expect(analysis.system[106..<250].allSatisfy { $0 < 0.001 })
    #expect(analysis.systemPeak(from: 0, to: 0.79) < 0.001)
    #expect(analysis.systemPeak(from: 0.81, to: 0.82) > 0.4)
    #expect(analysis.systemPeak(from: 0.815, to: 0.816) > 0.4)
    #expect(analysis.systemPeak(from: 0, to: 2.5) > 0.4)
    #expect(analysis.systemPeak(from: 1.06, to: 2.5) < 0.001)
    #expect(analysis.microphonePeak(from: 0, to: 2.5) == 0)
}

@Test func waveformPyramidMatchesBruteForcePeaks() {
    var peaks = [Float](repeating: 0, count: 5_000)
    var seed: UInt64 = 9
    for index in peaks.indices { seed = seed &* 6364136223846793005 &+ 1442695040888963407; peaks[index] = Float(seed >> 40) / Float(1 << 24) }
    let analysis = TimelineAnalysis(system: peaks)
    for (start, end) in [(0.0, 50.0), (0.123, 0.131), (3.3, 3.35), (10.0, 47.5), (0.0, 0.005), (49.99, 50.0), (12.34, 12.35), (0.07, 0.09), (5.115, 5.125), (1.0, 49.0), (0.0, 0.08)] {
        let first = Int(start * 100), last = min(peaks.count - 1, max(first, Int((end * 100).rounded(.up)) - 1))
        let expected = peaks[first...last].max() ?? 0
        // 金字塔查询必须和逐格扫描完全一致。
        #expect(analysis.systemPeak(from: start, to: end) == expected, "\(start)…\(end)")
    }
    #expect(analysis.systemPeak(from: 60, to: 70) == 0)
    #expect(analysis.systemPeak(from: 1, to: 1) == 0)
}

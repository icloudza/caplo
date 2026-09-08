import Foundation
import Testing
@testable import ExportKit
import EditingCore
import ProjectKit

/// 合成场景：麦克风 = 人声 + 延迟 190 毫秒并经过三径衰减的"音乐"回声 + 白噪声；另有只加噪声的版本。
struct VoiceScene {
    let rate = 48_000.0
    let count: Int
    let reference: [Float], voice: [Float], microphone: [Float], noisy: [Float], unrelated: [Float]
    let delay: Int

    init(seconds: Double = 6) {
        count = Int(rate * seconds)
        var seed: UInt32 = 0x1234_5678
        func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) * 2 - 1 }
        var reference = [Float](repeating: 0, count: count)
        var filtered: Float = 0
        for index in 0..<count {
            let t = Double(index) / rate
            var value = 0.0
            for (order, frequency) in [196.0, 330.0, 440.0, 659.0, 880.0, 1318.0].enumerated() {
                value += sin(2 * .pi * frequency * t + Double(order)) * (0.5 + 0.5 * sin(2 * .pi * (0.3 + Double(order) * 0.17) * t)) / 6
            }
            filtered = 0.98 * filtered + 0.02 * noise()
            reference[index] = Float(value) * 0.6 + filtered * 0.3
        }
        // 人声：基频从 132 Hz 滑到 158 Hz 再回来（相位累积，不与音乐的固定音高长期重合），带颤音与音节包络。
        var voice = [Float](repeating: 0, count: count)
        var phase = 0.0
        for index in 0..<count {
            let t = Double(index) / rate
            let pitch = 145 + 13 * sin(2 * .pi * 0.35 * t) + 2.5 * sin(2 * .pi * 5.5 * t)
            phase += 2 * .pi * pitch / rate
            guard (t > 1 && t < 2.5) || (t > 4 && t < 5.5) else { continue }
            let syllable = 0.5 + 0.5 * sin(2 * .pi * 4 * t)
            var value = 0.0
            for harmonic in 1...8 { value += sin(phase * Double(harmonic)) / Double(harmonic) }
            voice[index] = Float(value * syllable) * 0.35
        }
        delay = Int(0.19 * rate)
        var echo = [Float](repeating: 0, count: count)
        for index in 0..<count {
            for (tapDelay, gain) in [(0, Float(0.6)), (300, 0.25), (900, 0.1)] {
                let from = index - delay - tapDelay
                if from >= 0 { echo[index] += reference[from] * gain * 0.5 }
            }
        }
        var microphone = [Float](repeating: 0, count: count), noisy = [Float](repeating: 0, count: count), unrelated = [Float](repeating: 0, count: count)
        for index in 0..<count { microphone[index] = voice[index] + echo[index] + noise() * 0.01 }
        for index in 0..<count { noisy[index] = voice[index] + noise() * 0.02 }
        for index in 0..<count { unrelated[index] = noise() * 0.3 }
        self.reference = reference; self.voice = voice; self.microphone = microphone; self.noisy = noisy; self.unrelated = unrelated
    }

    func rms(_ signal: [Float], from: Double, to: Double) -> Float {
        let slice = signal[Int(from * rate)..<Int(to * rate)]
        return (slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
    }
    func correlation(_ a: [Float], _ b: [Float], from: Double, to: Double, lag: Int = 0) -> Float {
        let range = Int(from * rate)..<Int(to * rate)
        var ab: Float = 0, aa: Float = 0, bb: Float = 0
        for index in range {
            let shifted = index + lag
            guard shifted >= 0, shifted < a.count else { continue }
            ab += a[shifted] * b[index]; aa += a[shifted] * a[shifted]; bb += b[index] * b[index]
        }
        return ab / max(1e-9, (aa * bb).squareRoot())
    }
    /// 输出相对干净人声的最佳对齐（正值表示输出比人声晚）及该处的相关性。
    func bestLag(_ output: [Float], _ target: [Float], from: Double, to: Double, maxLag: Int = 1200) -> (lag: Int, correlation: Float) {
        var best = (lag: 0, correlation: -Float.infinity)
        for lag in stride(from: -maxLag, through: maxLag, by: 4) {
            let value = correlation(output, target, from: from, to: to, lag: lag)
            if value > best.correlation { best = (lag, value) }
        }
        return best
    }
    func decibels(_ ratio: Float) -> Float { 20 * log10(max(1e-9, ratio)) }
}

/// 两种引擎在同一合成场景上的基准：回声段压多少、人声保住多少、只降噪时噪声压多少；默认引擎必须过线。
@Test(arguments: VoiceProcessor.Engine.allCases) func voiceEnginesCancelEchoAndKeepVoice(engine: VoiceProcessor.Engine) {
    let scene = VoiceScene()
    let output = VoiceProcessor.process(microphone: scene.microphone, reference: scene.reference, sampleRate: scene.rate, engine: engine)
    #expect(output.count == scene.count)
    let echoReduction = scene.decibels(scene.rms(scene.microphone, from: 2.8, to: 3.8) / scene.rms(output, from: 2.8, to: 3.8))
    let voiceCorrelation = scene.correlation(output, scene.voice, from: 1.3, to: 2.3)
    let aligned = scene.bestLag(output, scene.voice, from: 1.3, to: 2.3)
    let voiceLevel = scene.rms(output, from: 1.3, to: 2.3) / scene.rms(scene.voice, from: 1.3, to: 2.3)
    let denoised = VoiceProcessor.process(microphone: scene.noisy, reference: nil, sampleRate: scene.rate, engine: engine)
    let noiseReduction = scene.decibels(scene.rms(scene.noisy, from: 3.0, to: 3.8) / scene.rms(denoised, from: 3.0, to: 3.8))
    let denoisedVoiceCorrelation = scene.correlation(denoised, scene.voice, from: 1.3, to: 2.3)
    let denoisedAligned = scene.bestLag(denoised, scene.voice, from: 1.3, to: 2.3)
    print(String(format: "BENCH %@: 回声压 %.1f dB，人声相关 %.3f（最佳对齐 %d 样本处 %.3f），人声电平 %.2f；只降噪：噪声压 %.1f dB，人声相关 %.3f（最佳对齐 %d 处 %.3f）",
                 engine.rawValue, echoReduction, voiceCorrelation, aligned.lag, aligned.correlation, voiceLevel, noiseReduction, denoisedVoiceCorrelation, denoisedAligned.lag, denoisedAligned.correlation))
    guard engine == VoiceProcessor.defaultEngine else { return }
    #expect(echoReduction >= 30, "回声段至少压 30 dB：\(echoReduction)")
    #expect(aligned.correlation > 0.95 && voiceLevel > 0.8, "人声要保住：\(aligned.correlation) / \(voiceLevel)")
    #expect(abs(aligned.lag) <= 8, "输出不能相对输入有可感知的延迟：\(aligned.lag)")
    #expect(noiseReduction >= 20 && denoisedAligned.correlation > 0.95, "只降噪：\(noiseReduction) / \(denoisedAligned.correlation)")
}

/// 纯线性回声（白噪参考、两径延迟）：本工程的回声消除收敛后至少压 40 dB，证明线性部分本身是对的。
@Test func nativeCancellerConvergesOnPureEcho() {
    let rate = 48_000.0, count = 48_000 * 4
    var seed: UInt32 = 99
    func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) * 2 - 1 }
    var far = [Float](repeating: 0, count: count)
    for index in 0..<count { far[index] = noise() * 0.3 }
    var near = [Float](repeating: 0, count: count)
    for index in 100..<count { near[index] = far[index - 100] * 0.5 + far[max(0, index - 400)] * 0.2 }
    let result = EchoCanceller(sampleRate: rate, partitions: 8).run(near: near, far: far)
    func rms(_ x: [Float], _ from: Int, _ to: Int) -> Float { (x[from..<to].reduce(0) { $0 + $1 * $1 } / Float(to - from)).squareRoot() }
    let reduction = 20 * log10(rms(near, count / 2, count) / max(1e-9, rms(result.residual, count / 2, count)))
    #expect(reduction >= 40, "\(reduction)")
}

/// 时延估计落在真实值附近；参考里没有麦克风能辨认的成分时判定为无回声（返回 nil）。
@Test func delayEstimateFindsTheEchoOrDeclinesUnrelatedReferences() {
    let scene = VoiceScene(seconds: 4)
    let estimated = VoiceProcessor.estimateDelay(reference: scene.reference, microphone: scene.microphone, sampleRate: scene.rate)
    #expect(estimated != nil && abs((estimated ?? 0) - scene.delay) <= 48, "时延估计 \(String(describing: estimated))，真实 \(scene.delay)")
    #expect(VoiceProcessor.estimateDelay(reference: scene.unrelated, microphone: scene.noisy, sampleRate: scene.rate) == nil)
}

/// 参考按片段偏移平移到麦克风采样序号上：正偏移补零起头，越界丢弃。
@Test func referenceAlignmentShiftsAndPads() {
    let shifted = VoiceProcessor.aligned([1, 2, 3, 4], shift: 2, count: 6)
    #expect(shifted == [0, 0, 1, 2, 3, 4])
    let advanced = VoiceProcessor.aligned([1, 2, 3, 4], shift: -1, count: 3)
    #expect(advanced == [2, 3, 4])
}

/// 合成时的素材选择：语音处理打开且产物存在才换用产物，否则一律录制文件；产物按算法版本命名。
@Test func compositionUsesProcessedMicrophoneOnlyWhenPresent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Media"), withIntermediateDirectories: true)
    let segment = SegmentRecord(id: 3, duration: 10, files: [.screen: "Media/000003-screen.mov", .microphone: "Media/000003-microphone.mov", .systemAudio: "Media/000003-systemAudio.mov"])
    let processed = try #require(VoiceProcessor.processedPath(for: segment))
    #expect(processed == "Media/000003-microphone-vp\(VoiceProcessor.version).caf")
    var levels = AudioLevels(); levels.voiceProcessing = true
    #expect(ProjectMedia.mediaPath(for: .microphone, in: segment, levels: levels, project: root) == "Media/000003-microphone.mov", "产物不存在时用录制文件")
    FileManager.default.createFile(atPath: root.appendingPathComponent(processed).path, contents: Data())
    #expect(ProjectMedia.mediaPath(for: .microphone, in: segment, levels: levels, project: root) == processed)
    #expect(ProjectMedia.mediaPath(for: .systemAudio, in: segment, levels: levels, project: root) == "Media/000003-systemAudio.mov")
    levels.voiceProcessing = false
    #expect(ProjectMedia.mediaPath(for: .microphone, in: segment, levels: levels, project: root) == "Media/000003-microphone.mov")
    #expect(VoiceProcessor.processedPath(for: SegmentRecord(id: 1, duration: 1, files: [.screen: "Media/000001-screen.mov"])) == nil)
}

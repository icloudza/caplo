import Accelerate
import AVFoundation
import EditingCore
import ProjectKit

/// 麦克风离线语音处理：以系统声音轨为参考消除扬声器串进麦克风的回声（频域分块自适应滤波，三遍收敛），
/// 再用短时谱增益压残余回声与底噪。全部在编辑器里离线完成，处理一次写成 CAF 放进工程，预览与导出共用；
/// 录制下来的原始麦克风文件不动，关掉开关就回到原始声音。
public enum VoiceProcessor {
    /// 算法版本进文件名：算法一改，旧产物自动失效重算。
    public static let version = 2
    public static let sampleRate = 48_000.0

    public static func processedPath(for segment: SegmentRecord) -> String? {
        segment.files[.microphone] == nil ? nil : String(format: "Media/%06d-microphone-vp%d.caf", segment.id, version)
    }

    /// 工程里有麦克风的片段是否都已有产物。
    public static func isProcessed(project: URL, document: ProjectDocument) -> Bool {
        document.segments.allSatisfy { segment in
            guard let path = processedPath(for: segment) else { return true }
            return (try? ProjectStorage.mediaURL(path, in: project)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    /// 逐片段处理（跳过已有产物）。参考信号按片段内的素材偏移对齐到麦克风时间轴；没有系统声音就只做降噪。
    public static func process(project: URL, document: ProjectDocument, progress: @escaping @Sendable (Double) -> Void) async throws {
        let pending = document.segments.filter { segment in
            guard let path = processedPath(for: segment), let url = try? ProjectStorage.mediaURL(path, in: project) else { return false }
            return !FileManager.default.fileExists(atPath: url.path)
        }
        for (index, segment) in pending.enumerated() {
            try Task.checkCancellation()
            guard let micPath = segment.files[.microphone], let outPath = processedPath(for: segment) else { continue }
            let micURL = try ProjectStorage.mediaURL(micPath, in: project)
            let outURL = try ProjectStorage.mediaURL(outPath, in: project)
            let microphone = try await readMono(url: micURL)
            var reference: [Float]?
            if let systemPath = segment.files[.systemAudio] {
                let system = try await readMono(url: try ProjectStorage.mediaURL(systemPath, in: project))
                // 系统声音的第 j 个样本在片段里的时刻是 offset(system) + j / sr；换算到麦克风的采样序号上。
                let shift = Int(((segment.offset(for: .microphone) - segment.offset(for: .systemAudio)) * sampleRate).rounded())
                reference = aligned(system, shift: shift, count: microphone.count)
            }
            try Task.checkCancellation()
            let processed = process(microphone: microphone, reference: reference, sampleRate: sampleRate)
            try Task.checkCancellation()
            try write(processed, to: outURL)
            progress(Double(index + 1) / Double(pending.count))
        }
        removeStaleOutputs(project: project)
        if pending.isEmpty { progress(1) }
    }

    /// 清掉旧算法版本的产物和中途被打断留下的临时文件。旧版本文件名对不上当前版本，永远不会再被读到，只占空间。
    static func removeStaleOutputs(project: URL) {
        let media = project.appendingPathComponent("Media")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: media.path) else { return }
        let current = "-microphone-vp\(version).caf"
        for name in names {
            let stale = name.hasPrefix(".") && name.hasSuffix(".partial.caf")
                || (name.range(of: #"-microphone-vp\d+\.caf$"#, options: .regularExpression) != nil && !name.hasSuffix(current))
            if stale { try? FileManager.default.removeItem(at: media.appendingPathComponent(name)) }
        }
    }

    /// 参考数组按 `shift` 平移到目标序号（正值表示参考比麦克风晚开始），不足补零。
    static func aligned(_ source: [Float], shift: Int, count: Int) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let from = index - shift
            if from >= 0, from < source.count { result[index] = source[from] }
        }
        return result
    }

    // MARK: - 纯算法

    /// 处理引擎（合成场景基准见 `VoiceProcessorTests`，2026-09-08）：`native` 是本工程的回声消除 + 谱后置滤波
    /// （回声压 25 dB、人声相关 0.997）；`nativeRNNoise` 再接 RNNoise 降噪（回声压 46 dB、人声相关 0.98、噪声压 33 dB），默认。
    /// 曾移植 SpeexDSP 的回声消除与预处理对比：消得深（35 dB）但双讲时人声相关只有 0.68、电平掉四成，已移除。
    public enum Engine: String, CaseIterable, Sendable { case native, nativeRNNoise }
    public static let defaultEngine = Engine.nativeRNNoise

    /// `microphone` 与 `reference` 在同一时间轴上、48 kHz 单声道；返回与麦克风等长的处理结果。
    public static func process(microphone: [Float], reference: [Float]?, sampleRate: Double, engine: Engine = defaultEngine) -> [Float] {
        guard !microphone.isEmpty else { return [] }
        let near = highPass(microphone, sampleRate: sampleRate, cutoff: 80)
        // 参考先按估计的时延对齐；峰不突出说明麦克风里没有可辨认的参考成分，就不做回声消除。
        var far: [Float]? = nil
        if let reference, reference.count == microphone.count, rms(reference) > 1e-4,
           let estimated = estimateDelay(reference: reference, microphone: near, sampleRate: sampleRate) {
            // 少对齐 5 毫秒：估计偏大时回声会跑到参考前面，那部分永远消不掉；滤波器的尾音长度足以吃下这点余量。
            let delay = max(0, estimated - Int(0.005 * sampleRate))
            far = Array(repeating: Float(0), count: delay) + reference.dropLast(min(delay, reference.count))
        }
        var residual = near, echoEstimate: [Float]? = nil
        if let far {
            let cancelled = EchoCanceller(sampleRate: sampleRate).run(near: near, far: far)
            residual = cancelled.residual; echoEstimate = cancelled.echo
        }
        let filtered = SpectralPostFilter().run(residual, echo: echoEstimate)
        let cleaned = engine == .nativeRNNoise ? RNNoiseFilter().process(filtered) : filtered
        return cleaned.map { min(1, max(-1, $0)) }
    }

    /// 参考到麦克风的时延（样本数）：先抽样到 12 kHz，做相位变换加权互相关（GCC-PHAT），只在 0…0.6 秒内找峰；
    /// 峰不够突出说明麦克风里没有可辨认的参考成分，返回 nil 不做回声消除。
    static func estimateDelay(reference: [Float], microphone: [Float], sampleRate: Double, maxDelay: Double = 0.6) -> Int? {
        let factor = 4
        let ref = decimate(reference, by: factor), mic = decimate(microphone, by: factor)
        let rate = sampleRate / Double(factor)
        let length = min(ref.count, mic.count, Int(rate * 20))
        guard length > Int(rate) else { return nil }
        let n = 1 << Int(ceil(log2(Double(length * 2))))
        let dft = ComplexDFT(count: n)
        let refRe = Array(ref.prefix(length)) + [Float](repeating: 0, count: n - length)
        let micRe = Array(mic.prefix(length)) + [Float](repeating: 0, count: n - length)
        let zero = [Float](repeating: 0, count: n)
        let R = dft.forward(real: refRe, imag: zero), M = dft.forward(real: micRe, imag: zero)
        // 互谱 M · conj(R)，按幅度归一化（PHAT），逆变换得到时延谱。
        var crossRe = [Float](repeating: 0, count: n), crossIm = [Float](repeating: 0, count: n)
        for bin in 0..<n {
            let re = M.re[bin] * R.re[bin] + M.im[bin] * R.im[bin]
            let im = M.im[bin] * R.re[bin] - M.re[bin] * R.im[bin]
            let magnitude = max(1e-9, (re * re + im * im).squareRoot())
            crossRe[bin] = re / magnitude; crossIm[bin] = im / magnitude
        }
        let correlation = dft.inverse(real: crossRe, imag: crossIm).re
        let maxLag = min(n - 1, Int(maxDelay * rate))
        var best = 0, bestValue = -Float.infinity
        var sum: Float = 0, sumSquares: Float = 0
        for lag in 0...maxLag {
            let value = correlation[lag]
            sum += value; sumSquares += value * value
            if value > bestValue { bestValue = value; best = lag }
        }
        let count = Float(maxLag + 1)
        let mean = sum / count, deviation = max(1e-9, (sumSquares / count - mean * mean).squareRoot())
        guard (bestValue - mean) / deviation > 6 else { return nil }
        return best * factor
    }

    static func decimate(_ signal: [Float], by factor: Int) -> [Float] {
        let count = signal.count / factor
        var result = [Float](repeating: 0, count: count)
        for index in 0..<count {
            var sum: Float = 0
            for offset in 0..<factor { sum += signal[index * factor + offset] }
            result[index] = sum / Float(factor)
        }
        return result
    }

    /// 零相位高通：二阶巴特沃斯正向滤一遍、反向再滤一遍（离线才能这么做），基频附近不产生相位偏移。
    static func highPass(_ signal: [Float], sampleRate: Double, cutoff: Double) -> [Float] {
        let forward = biquadHighPass(signal, sampleRate: sampleRate, cutoff: cutoff)
        return biquadHighPass(Array(forward.reversed()), sampleRate: sampleRate, cutoff: cutoff).reversed()
    }

    /// 二阶巴特沃斯高通（单向）。
    static func biquadHighPass(_ signal: [Float], sampleRate: Double, cutoff: Double) -> [Float] {
        let omega = 2 * Double.pi * cutoff / sampleRate
        let cosine = cos(omega), alpha = sin(omega) / (2 * 0.7071)
        let b0 = (1 + cosine) / 2, b1 = -(1 + cosine), b2 = (1 + cosine) / 2
        let a0 = 1 + alpha, a1 = -2 * cosine, a2 = 1 - alpha
        let c = [b0, b1, b2, a1, a2].map { $0 / a0 }
        var result = [Float](repeating: 0, count: signal.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for index in 0..<signal.count {
            let x = Double(signal[index])
            let y = c[0] * x + c[1] * x1 + c[2] * x2 - c[3] * y1 - c[4] * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            result[index] = Float(y)
        }
        return result
    }

    static func rms(_ signal: ArraySlice<Float>) -> Float {
        guard !signal.isEmpty else { return 0 }
        var value: Float = 0
        signal.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &value, vDSP_Length($0.count)) }
        return value
    }
    static func rms(_ signal: [Float]) -> Float { rms(signal[...]) }

    // MARK: - 文件读写

    /// 用 AVAssetReader 把素材读成 48 kHz 单声道浮点（多声道混成单声道）。
    static func readMono(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ProjectError.invalid("素材缺少声音轨道：\(url.lastPathComponent)") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ProjectError.invalid("无法读取声音素材。") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ProjectError.invalid("无法读取声音素材。") }
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes)
            bytes.withUnsafeBytes { raw in samples.append(contentsOf: raw.bindMemory(to: Float.self)) }
        }
        if reader.status == .failed { throw reader.error ?? ProjectError.invalid("读取声音素材失败。") }
        return samples
    }

    static func write(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))) else { throw ProjectError.invalid("无法建立声音缓冲。") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in buffer.floatChannelData!.pointee.update(from: source.baseAddress!, count: samples.count) }
        // 先写到同目录的隐藏临时文件，写完关闭后再原子改名。产物是否存在就是"处理过没有"的唯一判据，
        // 直接写正式文件名的话，中途被取消或崩溃留下的半截文件下次会被当成处理好的结果。
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).partial.caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try {
            let file = try AVAudioFile(forWriting: temporary, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }()   // 出了这个作用域 AVAudioFile 释放并关闭文件，之后才能改名。
        guard rename(temporary.path, url.path) == 0 else { throw ProjectError.invalid("无法保存处理后的声音：\(String(cString: strerror(errno)))") }
    }
}

/// 复数离散傅里叶变换（长度为 2 的幂），实信号放实部即可；逆变换已除以长度。
final class ComplexDFT {
    let count: Int
    private let forwardSetup: vDSP.DiscreteFourierTransform<Float>
    private let inverseSetup: vDSP.DiscreteFourierTransform<Float>
    init(count: Int) {
        self.count = count
        forwardSetup = try! vDSP.DiscreteFourierTransform(previous: nil, count: count, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        inverseSetup = try! vDSP.DiscreteFourierTransform(previous: nil, count: count, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
    }
    func forward(real: [Float], imag: [Float]) -> (re: [Float], im: [Float]) {
        var re = [Float](repeating: 0, count: count), im = [Float](repeating: 0, count: count)
        forwardSetup.transform(inputReal: real, inputImaginary: imag, outputReal: &re, outputImaginary: &im)
        return (re, im)
    }
    func inverse(real: [Float], imag: [Float]) -> (re: [Float], im: [Float]) {
        var re = [Float](repeating: 0, count: count), im = [Float](repeating: 0, count: count)
        inverseSetup.transform(inputReal: real, inputImaginary: imag, outputReal: &re, outputImaginary: &im)
        var scale = 1 / Float(count)
        vDSP_vsmul(re, 1, &scale, &re, 1, vDSP_Length(count)); vDSP_vsmul(im, 1, &scale, &im, 1, vDSP_Length(count))
        return (re, im)
    }
}

/// 频域分块（分区）自适应回声消除：块长 256、变换长 512、40 个分区约覆盖 213 毫秒尾音，每块按参考功率归一化步长。
/// 离线跑三遍：第一遍小步长整段学（双讲时也不会失控），据此按块算"回声抵消比"找出回声占主导的块；
/// 第二遍只在这些块上大步长学（人声与回声重叠的块冻结，不让人声把滤波器带偏）；第三遍同样门控、小步长输出。
/// 这是把双讲检测做成"用上一遍的结果回看"，实时算法做不到、离线正好。
struct EchoCanceller {
    let block = 256
    var partitions = 40
    var passes = 3
    var steps: [Float] = [0.1, 0.5, 0.2]
    /// 门控阈值：上一遍某块的回声抵消比低于此值就当作有近端人声，冻结更新。
    var gateDecibels: Float = 6
    let sampleRate: Double
    private let dft = ComplexDFT(count: 512)
    init(sampleRate: Double, partitions: Int = 40, passes: Int = 3, steps: [Float] = [0.1, 0.5, 0.2]) {
        self.sampleRate = sampleRate; self.partitions = partitions; self.passes = passes; self.steps = steps
    }

    struct Result { let residual: [Float]; let echo: [Float] }

    func run(near: [Float], far: [Float]) -> Result {
        let n = block, m = 2 * block, bins = m
        let blocks = near.count / n
        guard blocks > 2 else { return Result(residual: near, echo: [Float](repeating: 0, count: near.count)) }
        var filterRe = [[Float]](repeating: [Float](repeating: 0, count: bins), count: partitions)
        var filterIm = [[Float]](repeating: [Float](repeating: 0, count: bins), count: partitions)
        var residual = near, echo = [Float](repeating: 0, count: near.count)
        var gate: [Bool]? = nil
        let zero = [Float](repeating: 0, count: m)
        for pass in 0..<passes {
            var historyRe = [[Float]](repeating: [Float](repeating: 0, count: bins), count: partitions)
            var historyIm = [[Float]](repeating: [Float](repeating: 0, count: bins), count: partitions)
            var power = [Float](repeating: 0, count: bins)
            var head = 0
            let step: Float = steps[min(pass, steps.count - 1)]
            var erle = [Float](repeating: 0, count: blocks)
            for index in 0..<blocks {
                // 参考帧：上一块 + 当前块（重叠保留）。
                let start = index * n
                var frame = [Float](repeating: 0, count: m)
                for offset in 0..<m { let position = start - n + offset; if position >= 0, position < far.count { frame[offset] = far[position] } }
                let spectrum = dft.forward(real: frame, imag: zero)
                head = (head + partitions - 1) % partitions
                historyRe[head] = spectrum.re; historyIm[head] = spectrum.im
                // 各分区功率之和，作为归一化分母。
                var total = [Float](repeating: 0, count: bins)
                for p in 0..<partitions {
                    let slot = (head + p) % partitions
                    vDSP_vsq(historyRe[slot], 1, &power, 1, vDSP_Length(bins)); vDSP_vadd(total, 1, power, 1, &total, 1, vDSP_Length(bins))
                    vDSP_vsq(historyIm[slot], 1, &power, 1, vDSP_Length(bins)); vDSP_vadd(total, 1, power, 1, &total, 1, vDSP_Length(bins))
                }
                // 回声估计 Y = Σ H_p · X_{m-p}
                var yRe = [Float](repeating: 0, count: bins), yIm = [Float](repeating: 0, count: bins)
                for p in 0..<partitions {
                    let slot = (head + p) % partitions
                    complexMultiplyAdd(aRe: filterRe[p], aIm: filterIm[p], bRe: historyRe[slot], bIm: historyIm[slot], outRe: &yRe, outIm: &yIm)
                }
                let estimate = dft.inverse(real: yRe, imag: yIm).re
                var errorBlock = [Float](repeating: 0, count: n)
                var nearEnergy: Float = 0, errorEnergy: Float = 0, echoEnergy: Float = 0, cross: Float = 0
                for offset in 0..<n {
                    let d = near[start + offset], y = estimate[n + offset]
                    errorBlock[offset] = d - y
                    nearEnergy += d * d; errorEnergy += errorBlock[offset] * errorBlock[offset]; echoEnergy += y * y; cross += d * y
                }
                erle[index] = 10 * log10(max(1e-12, nearEnergy) / max(1e-12, errorEnergy))
                if pass == passes - 1 {
                    for offset in 0..<n { residual[start + offset] = errorBlock[offset]; echo[start + offset] = estimate[n + offset] }
                }
                // 参考太弱不更新；有门控时只在上一遍判定为回声主导的块上更新；
                // 麦克风与回声估计相关性低（近端在说话）时步长再缩到十分之一。
                let farEnergy = frame.reduce(0) { $0 + $1 * $1 }
                guard farEnergy > 1e-6 * Float(m) else { continue }
                if let gate, !gate[index] { continue }
                let coherence = cross / max(1e-9, (nearEnergy * echoEnergy).squareRoot())
                let effectiveStep = (gate != nil && echoEnergy > 1e-9 && coherence < 0.35) ? step * 0.1 : step
                let errorSpectrum = dft.forward(real: Array(zero.prefix(n)) + errorBlock, imag: zero)
                var meanPower: Float = 0
                vDSP_meanv(total, 1, &meanPower, vDSP_Length(bins))
                let regularization = max(1e-8, 1e-3 * meanPower)
                var gain = [Float](repeating: 0, count: bins)
                for bin in 0..<bins { gain[bin] = effectiveStep / (total[bin] + regularization) }
                for p in 0..<partitions {
                    let slot = (head + p) % partitions
                    // ΔH = μ · conj(X) · E / 功率，再把冲激响应后半段清零（约束型），防止循环卷积混叠。
                    var gRe = [Float](repeating: 0, count: bins), gIm = [Float](repeating: 0, count: bins)
                    complexConjugateMultiply(aRe: historyRe[slot], aIm: historyIm[slot], bRe: errorSpectrum.re, bIm: errorSpectrum.im, outRe: &gRe, outIm: &gIm)
                    vDSP_vmul(gRe, 1, gain, 1, &gRe, 1, vDSP_Length(bins)); vDSP_vmul(gIm, 1, gain, 1, &gIm, 1, vDSP_Length(bins))
                    var impulse = dft.inverse(real: gRe, imag: gIm)
                    for offset in n..<m { impulse.re[offset] = 0; impulse.im[offset] = 0 }
                    let constrained = dft.forward(real: impulse.re, imag: impulse.im)
                    vDSP_vadd(filterRe[p], 1, constrained.re, 1, &filterRe[p], 1, vDSP_Length(bins))
                    vDSP_vadd(filterIm[p], 1, constrained.im, 1, &filterIm[p], 1, vDSP_Length(bins))
                }
            }
            // 下一遍的门：这一遍抵消得好的块才是"只有回声"的块。
            gate = erle.map { $0 >= gateDecibels }
        }
        return Result(residual: residual, echo: echo)
    }

    private func complexMultiplyAdd(aRe: [Float], aIm: [Float], bRe: [Float], bIm: [Float], outRe: inout [Float], outIm: inout [Float]) {
        let count = aRe.count
        var aRe = aRe, aIm = aIm, bRe = bRe, bIm = bIm
        aRe.withUnsafeMutableBufferPointer { ar in aIm.withUnsafeMutableBufferPointer { ai in bRe.withUnsafeMutableBufferPointer { br in bIm.withUnsafeMutableBufferPointer { bi in
            outRe.withUnsafeMutableBufferPointer { orp in outIm.withUnsafeMutableBufferPointer { oip in
                var a = DSPSplitComplex(realp: ar.baseAddress!, imagp: ai.baseAddress!)
                var b = DSPSplitComplex(realp: br.baseAddress!, imagp: bi.baseAddress!)
                var out = DSPSplitComplex(realp: orp.baseAddress!, imagp: oip.baseAddress!)
                vDSP_zvma(&a, 1, &b, 1, &out, 1, &out, 1, vDSP_Length(count))
            } }
        } } } }
    }

    private func complexConjugateMultiply(aRe: [Float], aIm: [Float], bRe: [Float], bIm: [Float], outRe: inout [Float], outIm: inout [Float]) {
        let count = aRe.count
        var aRe = aRe, aIm = aIm, bRe = bRe, bIm = bIm
        aRe.withUnsafeMutableBufferPointer { ar in aIm.withUnsafeMutableBufferPointer { ai in bRe.withUnsafeMutableBufferPointer { br in bIm.withUnsafeMutableBufferPointer { bi in
            outRe.withUnsafeMutableBufferPointer { orp in outIm.withUnsafeMutableBufferPointer { oip in
                var a = DSPSplitComplex(realp: ar.baseAddress!, imagp: ai.baseAddress!)
                var b = DSPSplitComplex(realp: br.baseAddress!, imagp: bi.baseAddress!)
                var out = DSPSplitComplex(realp: orp.baseAddress!, imagp: oip.baseAddress!)
                // conj(A) · B
                vDSP_zvcmul(&a, 1, &b, 1, &out, 1, vDSP_Length(count))
            } }
        } } } }
    }
}

/// 短时谱后置滤波：帧长 1024、跳 256、开方汉宁窗；噪声谱用最小值统计跟踪，残余回声谱取回声估计的一部分，
/// 判决引导法估计先验信噪比后用维纳增益，纯噪声段留 -15 dB 底、残余回声段留 -22 dB 底，避免"水声"伪影。
struct SpectralPostFilter {
    let frame = 1024
    let hop = 256
    private let dft = ComplexDFT(count: 1024)

    func run(_ signal: [Float], echo: [Float]?) -> [Float] {
        guard signal.count >= frame else { return signal }
        let bins = frame / 2 + 1
        let window: [Float] = (0..<frame).map { Float(sin(Double.pi * (Double($0) + 0.5) / Double(frame))) }   // 开方汉宁（周期）
        let zero = [Float](repeating: 0, count: frame)
        let frames = (signal.count - frame) / hop + 1
        var output = [Float](repeating: 0, count: signal.count)
        var normalization = [Float](repeating: 0, count: signal.count)
        var noise = [Float](repeating: 0, count: bins)
        var smoothed = [Float](repeating: 0, count: bins)
        var windowMinimum = [Float](repeating: .greatestFiniteMagnitude, count: bins)
        var previousMinimum = [Float](repeating: .greatestFiniteMagnitude, count: bins)
        var residualEcho = [Float](repeating: 0, count: bins)
        var previousClean = [Float](repeating: 0, count: bins)
        let minimumWindow = 150
        for index in 0..<frames {
            let start = index * hop
            var segment = [Float](repeating: 0, count: frame)
            for offset in 0..<frame { segment[offset] = signal[start + offset] * window[offset] }
            let spectrum = dft.forward(real: segment, imag: zero)
            var echoPower = [Float](repeating: 0, count: bins)
            if let echo {
                var echoSegment = [Float](repeating: 0, count: frame)
                for offset in 0..<frame { echoSegment[offset] = echo[start + offset] * window[offset] }
                let echoSpectrum = dft.forward(real: echoSegment, imag: zero)
                for bin in 0..<bins { echoPower[bin] = echoSpectrum.re[bin] * echoSpectrum.re[bin] + echoSpectrum.im[bin] * echoSpectrum.im[bin] }
            }
            var gains = [Float](repeating: 1, count: bins)
            for bin in 0..<bins {
                let power = spectrum.re[bin] * spectrum.re[bin] + spectrum.im[bin] * spectrum.im[bin]
                smoothed[bin] = 0.8 * smoothed[bin] + 0.2 * power
                windowMinimum[bin] = min(windowMinimum[bin], smoothed[bin])
                if index < 8 { noise[bin] = max(noise[bin], smoothed[bin]) }   // 开头几帧先当噪声底
                else { noise[bin] = 1.5 * min(windowMinimum[bin], previousMinimum[bin]) }
                residualEcho[bin] = 0.7 * residualEcho[bin] + 0.3 * 0.35 * echoPower[bin]
                let interference = noise[bin] + residualEcho[bin] + 1e-12
                let posterior = max(0, power / interference - 1)
                let prior = 0.97 * (previousClean[bin] / interference) + 0.03 * posterior
                var gain = prior / (1 + prior)
                let floor: Float = residualEcho[bin] > 3 * noise[bin] ? 0.08 : 0.18
                gain = max(floor, min(1, gain))
                gains[bin] = gain
                previousClean[bin] = gain * gain * power
            }
            if (index + 1) % minimumWindow == 0 {
                previousMinimum = windowMinimum
                windowMinimum = [Float](repeating: .greatestFiniteMagnitude, count: bins)
            }
            var re = spectrum.re, im = spectrum.im
            for bin in 0..<bins {
                re[bin] *= gains[bin]; im[bin] *= gains[bin]
                if bin > 0, bin < bins - 1 { re[frame - bin] *= gains[bin]; im[frame - bin] *= gains[bin] }
            }
            let cleaned = dft.inverse(real: re, imag: im).re
            for offset in 0..<frame {
                output[start + offset] += cleaned[offset] * window[offset]
                normalization[start + offset] += window[offset] * window[offset]
            }
        }
        for index in 0..<signal.count where normalization[index] > 1e-6 { output[index] /= normalization[index] }
        // 尾部不足一帧的样本保持原样。
        let covered = (frames - 1) * hop + frame
        if covered < signal.count { for index in covered..<signal.count { output[index] = signal[index] } }
        return output
    }
}

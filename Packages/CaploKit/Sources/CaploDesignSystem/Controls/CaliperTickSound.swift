import AVFoundation
import Foundation

/// 卡尺发声接口；测试可换成记录器。
@MainActor public protocol CaliperTickPlaying: AnyObject {
    func tick()
}

/// 合成的机械"咔嗒"：短促的高频衰减正弦加一点噪声爆发和低频"体"，只有一种声音。
/// 引擎第一次需要时在后台线程启动（启动要几十毫秒，不能卡主线程），之后常驻不停：
/// 停起循环会让 CoreAudio 打出 HALPlugIn "stop" 错误，重启时还会在第一声上卡一下。引擎起不来（没有输出设备）就静默。
@MainActor public final class CaliperTickSound: CaliperTickPlaying {
    public static let shared = CaliperTickSound()
    public var volume: Float = 0.45
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var click: AVAudioPCMBuffer?
    private var starting = false
    private var failed = false

    public func tick() {
        guard let engine, engine.isRunning, let player, let click else { prepareIfNeeded(); return }
        player.volume = volume
        player.scheduleBuffer(click, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func prepareIfNeeded() {
        guard !starting, !failed, let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else { return }
        starting = true
        let engine = self.engine ?? AVAudioEngine()
        let player = self.player ?? AVAudioPlayerNode()
        if self.engine == nil {
            engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
            self.engine = engine; self.player = player
            click = Self.click(format: format, tone: 1700, body: 420, duration: 0.011, amplitude: 0.6)
        }
        // 启动放到后台：第一声可能来不及（吞掉），之后每一声都即时。
        let box = EngineBox(engine: engine)
        Task.detached(priority: .userInitiated) {
            let ok = (try? box.engine.start()) != nil
            await MainActor.run { self.starting = false; if !ok { self.failed = true } }
        }
    }
    /// 只为把引擎带进后台任务：AVAudioEngine 的启动本身线程安全，启动完成后仍只在主线程使用。
    private struct EngineBox: @unchecked Sendable { let engine: AVAudioEngine }

    /// 0.4 毫秒起音避免爆音；三个成分各自指数衰减。
    static func click(format: AVAudioFormat, tone: Double, body: Double, duration: Double, amplitude: Float) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate, frames = AVAudioFrameCount(duration * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let channel = buffer.floatChannelData?.pointee else { return nil }
        buffer.frameLength = frames
        var seed: UInt32 = 0x9E37_79B9
        for index in 0..<Int(frames) {
            let time = Double(index) / rate
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed >> 8) / Double(1 << 24) * 2 - 1
            let attack = min(1, time / 0.0004)
            let sample = sin(2 * .pi * tone * time) * exp(-time / 0.0016) * 0.6
                + noise * exp(-time / 0.0006) * 0.5
                + sin(2 * .pi * body * time) * exp(-time / 0.0035) * 0.35
            channel[index] = Float(sample * attack) * amplitude
        }
        return buffer
    }
}

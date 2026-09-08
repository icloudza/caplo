import AVFoundation
import Observation

/// 录制条上的麦克风试听：选中麦克风就开始采集（只算电平不写盘、不回放），方便调整设备与系统麦克风模式，
/// iPhone 这类连续互通设备也会马上激活；按 REC 后由录制器接管。起不来就按退避间隔一直重试（设备可能还在连接），
/// 采集中断也自动重来。
@MainActor @Observable public final class MicrophoneMonitor {
    public static let shared = MicrophoneMonitor()
    /// 0…1，带衰减的平滑电平。
    public private(set) var level: Float = 0
    public private(set) var active = false
    public private(set) var error: String?
    private var capture: MicrophoneCapture?
    private var configuration: String??
    private var generation = 0

    /// `deviceID` 为空用系统默认输入；同一配置重复调用不重启。
    public func start(deviceID: String?) {
        if let configuration, configuration == deviceID { return }
        stop()
        configuration = .some(deviceID)
        generation += 1
        run(deviceID: deviceID, run: generation)
    }

    public func stop() {
        generation += 1
        capture?.stop(); capture = nil
        configuration = nil
        active = false; level = 0
    }

    private func run(deviceID: String?, run: Int) {
        Task { [weak self] in
            guard await AVCaptureDevice.requestAccess(for: .audio) else { self?.error = "麦克风访问未获允许。"; return }
            var delay = 1_500
            while true {
                guard let self, self.generation == run else { return }
                if await self.attempt(deviceID: deviceID, run: run) { return }
                try? await Task.sleep(for: .milliseconds(delay))
                delay = min(5_000, delay * 2)
            }
        }
    }

    /// 一轮尝试；起不来返回 false 由外层重试。
    private func attempt(deviceID: String?, run: Int) async -> Bool {
        guard let device = deviceID ?? AVCaptureDevice.default(for: .audio)?.uniqueID else { error = "没有可用的麦克风。"; return false }
        let capture = MicrophoneCapture(writer: nil, level: { [weak self] value in
            Task { @MainActor in self?.receive(value, run: run) }
        }, onFailure: { [weak self] message in
            Task { @MainActor in self?.interrupted(message, run: run) }
        })
        do {
            try await capture.start(deviceID: device)
            guard generation == run else { capture.stop(); return true }
            self.capture = capture; active = true; error = nil
            MicrophoneModes.shared.startObserving()
            return true
        } catch {
            // 起不来的引擎也走 stop，让它按同样的节奏延迟释放。
            capture.stop()
            self.error = error.localizedDescription
            return false
        }
    }

    /// 采集中断（设备拔出、默认设备改变）：按原配置重新来。
    private func interrupted(_ message: String, run: Int) {
        guard generation == run, let configuration else { return }
        error = message
        capture?.stop(); capture = nil
        active = false; level = 0
        generation += 1
        self.run(deviceID: configuration, run: generation)
    }

    private func receive(_ value: Float, run: Int) {
        guard generation == run else { return }
        // 快起慢落：新值更高立刻跟上，否则每块衰减 15%，说话的起伏看得见。
        level = max(value, level * 0.85)
    }
}

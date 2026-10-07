import AVFoundation
import Observation

/// 录制条上的麦克风试听：选中麦克风就开始采集（只算电平不写盘、不回放），方便调整设备与系统麦克风模式，
/// iPhone 这类连续互通设备也会马上激活；按 REC 后录制器借用这路采集（`borrow`）挂上写入器，引擎不停不重开。起不来就按退避间隔一直重试（设备可能还在连接），
/// 采集中断也自动重来。
@MainActor @Observable public final class MicrophoneMonitor {
    public static let shared = MicrophoneMonitor()
    /// 0…1：相对环境底噪的响度（底噪之上才算有声音），快起慢落。
    public private(set) var level: Float = 0
    /// 底噪估计（dB）：读数更低立刻跟下去，否则每块只抬 0.005 dB（约 0.5 dB/s），说话不会把底噪抬上去。
    @ObservationIgnored private var noiseFloor: Float?
    public private(set) var active = false
    public private(set) var error: String?
    /// 正在采集的设备 uniqueID（试听起来后才有），录制器据此判断能否直接借用。
    public private(set) var deviceUID: String?
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
        configuration = nil; deviceUID = nil
        active = false; level = 0; noiseFloor = nil
    }

    /// 只给离线预览用：不采集，直接摆出"试听中、某个电平"的样子。
    public func simulate(level: Float) { active = true; self.level = level }

    /// 音波只反映"比安静时响多少"：底噪之上 6 dB 起算，再高 24 dB 满格；单纯的环境噪声显示为小点。
    nonisolated static func displayLevel(decibels: Float, floor: Float) -> Float {
        min(1, max(0, (decibels - floor - 6) / 24))
    }
    nonisolated static func updatedFloor(_ floor: Float?, reading: Float) -> Float {
        guard let floor else { return reading }
        return min(reading, floor + 0.005)
    }

    /// 录制器借用试听中的采集：设备一致就把写入器挂上去，引擎不重启（iPhone 的麦克风不会灭一下再亮，
    /// 语音处理单元的默认输入切换也不来回折腾）。没在试听或设备不一致返回 false，录制器自己起一路。
    func borrow(deviceID: String, writer: SegmentedCaptureWriter, onFailure: @escaping @Sendable (String) -> Void) -> Bool {
        guard active, deviceUID == deviceID, let capture else { return false }
        capture.attach(writer: writer, onFailure: onFailure)
        return true
    }
    func release() { capture?.detach() }

    private func run(deviceID: String?, run: Int) {
        Task { [weak self] in
            guard await AVCaptureDevice.requestAccess(for: .audio) else { self?.error = String(localized: "麦克风访问未获允许。"); return }
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
        guard let device = deviceID ?? AVCaptureDevice.default(for: .audio)?.uniqueID else { error = String(localized: "没有可用的麦克风。"); return false }
        let capture = MicrophoneCapture(writer: nil, level: { [weak self] value in
            Task { @MainActor in self?.receive(value, run: run) }
        }, onFailure: { [weak self] message in
            Task { @MainActor in self?.interrupted(message, run: run) }
        })
        do {
            try await capture.start(deviceID: device)
            guard generation == run else { capture.stop(); return true }
            self.capture = capture; deviceUID = device; active = true; error = nil
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
        capture?.stop(); capture = nil; deviceUID = nil
        active = false; level = 0
        generation += 1
        self.run(deviceID: configuration, run: generation)
    }

    private func receive(_ value: Float, run: Int) {
        guard generation == run else { return }
        let decibels = MicrophoneCapture.decibels(level: value)
        let floor = Self.updatedFloor(noiseFloor, reading: decibels)
        noiseFloor = floor
        // 快起慢落：新值更高立刻跟上，否则每块衰减 15%，说话的起伏看得见。
        level = max(Self.displayLevel(decibels: decibels, floor: floor), level * 0.85)
    }
}

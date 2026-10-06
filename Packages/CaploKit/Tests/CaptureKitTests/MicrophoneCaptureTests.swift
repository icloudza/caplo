import AVFoundation
import CoreAudio
import CoreMedia
import Testing
import ProjectKit
@testable import CaptureKit

/// 录制器借用试听中的采集：写入器随时挂上 / 摘下，引擎不动；没在试听时借不到（摄像头会话同理），录制器自己起一路。
@MainActor @Test func recorderBorrowsTheMonitoredCaptureWithoutRestarting() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "借用麦克风")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: true, onStarted: {}, onFailure: { _ in })
    let capture = MicrophoneCapture(writer: nil, onFailure: { _ in })
    #expect(!capture.isAttached)
    capture.attach(writer: writer, onFailure: { _ in })
    #expect(capture.isAttached)
    capture.detach()
    #expect(!capture.isAttached)
    let recording = MicrophoneCapture(writer: writer, onFailure: { _ in })
    #expect(recording.isAttached)
    #expect(!MicrophoneMonitor.shared.active && MicrophoneMonitor.shared.deviceUID == nil)
    let borrowed = MicrophoneMonitor.shared.borrow(deviceID: "any", writer: writer, onFailure: { _ in })
    #expect(!borrowed)
    MicrophoneMonitor.shared.release()
    #expect(CameraMonitor.shared.borrowFeed(for: "any", format: nil) == nil)
}

/// 语音处理单元借用系统默认输入：崩溃或强退来不及恢复时，下次启动按记录改回去；
/// 用户之后自己换过默认输入的，不去动它，只清记录。
@Test func defaultInputLeftBehindByACrashIsRestoredOnlyIfStillOurs() {
    let defaults = UserDefaults(suiteName: "caplo.test.\(UUID().uuidString)")!
    defaults.set(["from": "built-in", "to": "usb-mic"], forKey: MicrophoneCapture.switchedDefaultInputKey)
    var restored: [String] = []
    let changed = MicrophoneCapture.restoreDefaultInputLeftBehind(defaults: defaults, current: { "usb-mic" }, restore: { restored.append($0); return true })
    #expect(changed && restored == ["built-in"], "默认输入还停在借过去的麦克风，应当改回原来的设备")
    #expect(defaults.dictionary(forKey: MicrophoneCapture.switchedDefaultInputKey) == nil, "改回之后记录没有清掉")

    defaults.set(["from": "built-in", "to": "usb-mic"], forKey: MicrophoneCapture.switchedDefaultInputKey)
    restored = []
    let untouched = MicrophoneCapture.restoreDefaultInputLeftBehind(defaults: defaults, current: { "airpods" }, restore: { restored.append($0); return true })
    #expect(!untouched && restored.isEmpty, "用户自己换过默认输入，不应当被改回")
    #expect(defaults.dictionary(forKey: MicrophoneCapture.switchedDefaultInputKey) == nil)

    // 没有记录（正常退出时停止就清掉了）：什么都不做。
    #expect(!MicrophoneCapture.restoreDefaultInputLeftBehind(defaults: defaults, current: { "usb-mic" }, restore: { _ in Issue.record("不该恢复"); return true }))
}

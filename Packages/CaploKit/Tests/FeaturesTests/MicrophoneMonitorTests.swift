import Foundation
import Testing
import CaptureKit
@testable import Features

/// 预览模型和关掉麦克风时不启动试听（也就不会申请麦克风权限）；试听器停下后电平归零。
@MainActor @Test func previewAndMicrophoneOffNeverStartMonitoring() throws {
    let defaults = try #require(UserDefaults(suiteName: "caplo.tests.monitor." + UUID().uuidString))
    defaults.set(true, forKey: "recording.microphone")
    RecordBarModel.preview().syncMicrophoneMonitor(defaults: defaults)
    #expect(!MicrophoneMonitor.shared.active && MicrophoneMonitor.shared.level == 0)
    let model = RecordBarModel(mode: .display, source: CaptureSource(id: "display-1", title: "显示器", kind: .display))
    defaults.set(false, forKey: "recording.microphone")
    model.syncMicrophoneMonitor(defaults: defaults)
    #expect(!MicrophoneMonitor.shared.active)
    MicrophoneMonitor.shared.stop()
    #expect(!MicrophoneMonitor.shared.active && MicrophoneMonitor.shared.level == 0)
}

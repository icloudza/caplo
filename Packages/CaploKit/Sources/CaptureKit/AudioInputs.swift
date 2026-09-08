import AppKit
import AVFoundation

public struct CaptureMicrophone: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct CaptureAudioApplication: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// 枚举设备与正在运行的应用不启动采集；系统权限仍在用户开始录制时按需申请。
@MainActor
public enum AudioInputCatalog {
    public static func microphones() -> [CaptureMicrophone] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.filter { MicrophoneCapture.isSelectableMicrophone(uid: $0.uniqueID) }
            .map { CaptureMicrophone(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func applications() -> [CaptureAudioApplication] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.activationPolicy == .regular, !application.isTerminated,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let id = application.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return CaptureAudioApplication(id: id, name: application.localizedName ?? id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// 空设备 ID 代表系统默认输入；系统声音的 nil 应用列表代表全部，空数组明确代表尚未选择。
/// 二者不能混用，否则用户选择的“仅指定应用”可能意外退回采集所有声音。
struct RecordingAudioPlan: Equatable, Sendable {
    let microphoneDeviceID: String?
    let systemAudio: Bool
    let applicationBundleIDs: [String]?

    static func resolve(options: RecordingOptions, microphones: [CaptureMicrophone], defaultMicrophoneID: String?, applicationIDs: Set<String>) throws -> Self {
        let microphoneID: String?
        if options.microphone {
            guard let chosen = options.microphoneDeviceID ?? defaultMicrophoneID,
                  microphones.contains(where: { $0.id == chosen }) else {
                throw RecordingError.message("所选麦克风未连接。请选择可用设备，或关闭麦克风后录制。")
            }
            microphoneID = chosen
        } else { microphoneID = nil }
        var selection: [String]?
        if options.systemAudio, let requested = options.systemAudioApplicationBundleIDs {
            let unique = Array(Set(requested)).sorted()
            guard !unique.isEmpty else { throw RecordingError.message("请至少选择一个声音应用，或切换为全部系统声音。") }
            let missing = unique.filter { id in !applicationIDs.contains(where: { matches(application: $0, selection: id) }) }
            guard missing.isEmpty else { throw RecordingError.message("所选声音应用已退出或不可用，请重新选择后录制。") }
            selection = unique
        }
        return Self(microphoneDeviceID: microphoneID, systemAudio: options.systemAudio, applicationBundleIDs: selection)
    }

    /// 同一应用的辅助进程可能有独立标识，使用点边界匹配，不误选名称相似的其他应用。
    static func matches(application: String, selection: String) -> Bool {
        application == selection || application.hasPrefix(selection + ".")
    }
}

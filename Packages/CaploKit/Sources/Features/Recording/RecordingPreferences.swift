import SwiftUI
import AppKit
import CaptureKit
import CaploDesignSystem

/// 录制动作读取持久化选择的同一快照，避免界面显示选择了设备、引擎却仍用默认输入。
enum RecordingAudioPreferences {
    static func apply(to options: inout RecordingOptions, defaults: UserDefaults = .standard) {
        let id = defaults.string(forKey: "recording.microphoneDeviceID") ?? ""
        options.microphoneDeviceID = id.isEmpty ? nil : id
        if defaults.string(forKey: "recording.systemAudioScope") == "applications" {
            let data = defaults.data(forKey: "recording.systemAudioApplications") ?? Data()
            options.systemAudioApplicationBundleIDs = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        } else { options.systemAudioApplicationBundleIDs = nil }
    }
}

/// 选择设备不会开启摄像头；开关与设备 ID 在开始录制时一并读取。
enum RecordingCameraPreferences {
    static func apply(to options: inout RecordingOptions, defaults: UserDefaults = .standard) {
        options.camera = defaults.bool(forKey: "recording.camera")
        let id = defaults.string(forKey: "recording.cameraDeviceID") ?? ""
        options.cameraDeviceID = id.isEmpty ? nil : id
        options.cameraFormat = CameraFormat(key: defaults.string(forKey: "recording.cameraFormat"))
    }
}

/// 录制条上三路输入的显示名称；关闭状态由各自开关决定，设备偏好在关闭时保留。
enum RecordingDeviceNames {
    /// 所选设备不在线时返回 nil，调用方按"关"显示；空 id 表示系统默认，只要有任一设备就可用。
    static func camera(id: String, cameras: [CaptureCamera]) -> String? {
        id.isEmpty ? (cameras.isEmpty ? nil : "默认摄像头") : cameras.first(where: { $0.id == id }).map { short($0.name) }
    }
    static func microphone(id: String, devices: [CaptureMicrophone]) -> String? {
        id.isEmpty ? (devices.isEmpty ? nil : "默认麦克风") : devices.first(where: { $0.id == id }).map { short($0.name) }
    }
    /// 录制条上的短名：图标已经说明是摄像头还是麦克风，去掉系统名里的引号和"的相机 / 的麦克风"这类后缀
    /// （“云之安的 iPhone”的相机 → 云之安的 iPhone）；菜单里仍显示完整名。
    static func short(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespaces)
        for suffix in ["的相机", "的摄像头", "的麦克风", " Camera", " Microphone"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count)); break
        }
        text = text.trimmingCharacters(in: .whitespaces)
        if let first = text.first, let last = text.last, "“\"".contains(first), "”\"".contains(last), text.count > 2 {
            text = String(text.dropFirst().dropLast())
        }
        return text.isEmpty ? name : text
    }
    /// 空 id（系统默认）在有任一设备时可用；指定 id 必须在线。
    static func available(id: String, in ids: [String]) -> Bool { id.isEmpty ? !ids.isEmpty : ids.contains(id) }
    static func systemAudio(scope: String, selected: Set<String>, applications: [CaptureAudioApplication]) -> String {
        if scope == "all" { return "系统声音" }
        if selected.count == 1, let id = selected.first {
            return applications.first(where: { $0.id == id })?.name ?? "所选应用未运行"
        }
        return selected.isEmpty ? "选声音应用…" : "\(selected.count) 个应用"
    }
    static func decodeApplications(_ data: Data) -> Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: data)) ?? [])
    }
    static func encodeApplications(_ values: Set<String>) -> Data {
        (try? JSONEncoder().encode(values.sorted())) ?? Data()
    }
}

/// 指定应用的系统声音选择器，从录制条的系统声音下拉打开；空选择不等于全部。
struct SystemAudioApplicationPicker: View {
    @AppStorage("recording.systemAudioApplications") private var applicationData = Data()
    @State private var applications: [CaptureAudioApplication] = AudioInputCatalog.applications()
    @State private var query = ""
    let done: () -> Void

    private var selected: Set<String> { RecordingDeviceNames.decodeApplications(applicationData) }

    var body: some View {
        VStack(alignment: .leading, spacing: CaploMetrics.Spacing.m) {
            HStack {
                Text("指定声音应用").font(CaploFont.panelTitle).foregroundStyle(CaploColor.textPrimary)
                Spacer()
                Button { applications = AudioInputCatalog.applications() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(StudioIconButtonStyle(size: .small)).help("刷新应用").accessibilityLabel("刷新应用")
            }
            TextField("搜索应用", text: $query).textFieldStyle(.plain)
                .foregroundStyle(CaploColor.textPrimary).environment(\.colorScheme, .dark)
                .padding(CaploMetrics.Spacing.s)
                .caploMaterial(.raised, cornerRadius: CaploMetrics.Radius.control)
            ScrollView {
                VStack(alignment: .leading, spacing: CaploMetrics.Spacing.xs) {
                    ForEach(applications.filter { query.isEmpty || $0.name.localizedStandardContains(query) }) { application in
                        Toggle(application.name, isOn: Binding(get: { selected.contains(application.id) }, set: { on in
                            var values = selected
                            if on { values.insert(application.id) } else { values.remove(application.id) }
                            applicationData = RecordingDeviceNames.encodeApplications(values)
                        })).toggleStyle(.checkbox).environment(\.colorScheme, .dark)
                            .font(CaploFont.body).padding(CaploMetrics.Spacing.s).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    let missing = selected.subtracting(applications.map(\.id))
                    if !missing.isEmpty {
                        Text("\(missing.count) 个已选应用当前未运行").font(CaploFont.caption).foregroundStyle(CaploColor.warning)
                        Button("移除未运行应用") { applicationData = RecordingDeviceNames.encodeApplications(selected.subtracting(missing)) }
                            .buttonStyle(StudioButtonStyle(.secondary, size: .small))
                    }
                    if applications.isEmpty {
                        Text("没有可选择的应用，请先打开要录制声音的应用。").font(CaploFont.caption).foregroundStyle(CaploColor.textTertiary)
                    }
                }
            }.frame(maxHeight: 240)
            StudioDivider()
            HStack {
                Text("已选 \(selected.count) 个应用").font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
                Spacer()
                Button("完成", action: done).buttonStyle(StudioButtonStyle(.primary))
            }
        }
        .padding(CaploMetrics.Spacing.l)
        .frame(width: 340)
        // 弹层是独立窗口，单独采样其背后内容；不继承系统弹层的实色底。
        .background(CaploMaterialBackground(.floating))
        .presentationBackground(.clear)
        .foregroundStyle(CaploColor.textPrimary)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in applications = AudioInputCatalog.applications() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in applications = AudioInputCatalog.applications() }
    }
}

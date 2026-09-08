import SwiftUI
import AppKit
import AVFoundation
import CaptureKit
import CaploDesignSystem

/// 贴底录制条：× ｜ 方式图标 ｜ ⚙ ▾ ｜ 摄像头 ▾ ｜ 麦克风 ▾ ｜ 系统声音 ▾ ｜ REC。
/// 左侧不显示来源名称：来源、重新选择、倒计时与光标都收进齿轮菜单，当前来源在悬停提示与遮罩标签里可见。
/// 三路输入的开关与设备互相独立：下拉里"关闭"只改开关，选设备会同时开启。
public struct RecordBarView: View {
    /// 高度 = 错误提示行 24 + 间距 8 + 浮动条 56 + 面板留白 12。
    public static let panelSize = CGSize(width: 860, height: 100)
    private let model: RecordBarModel
    @AppStorage("recording.microphone") private var microphone = false
    @AppStorage("recording.systemAudio") private var systemAudio = false
    @AppStorage("recording.camera") private var camera = false
    @AppStorage("recording.cameraDeviceID") private var cameraID = ""
    @AppStorage("recording.microphoneDeviceID") private var microphoneID = ""
    @AppStorage("recording.systemAudioScope") private var scope = "all"
    @AppStorage("recording.systemAudioApplications") private var applicationData = Data()
    @AppStorage("recording.countdown") private var countdown = 3
    @AppStorage("recording.frameRate") private var frameRate = 60
    @State private var devices: [CaptureMicrophone] = []
    @State private var cameras: [CaptureCamera] = []
    @State private var applications: [CaptureAudioApplication] = []
    @State private var choosingApplications = false

    public init(model: RecordBarModel) { self.model = model }

    private var selectedApplications: Set<String> { RecordingDeviceNames.decodeApplications(applicationData) }

    public var body: some View {
        VStack(alignment: .center, spacing: CaploMetrics.Spacing.s) {
            Spacer(minLength: 0)
            if let error = model.errorMessage {
                HStack(spacing: CaploMetrics.Spacing.xs + 2) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(error).lineLimit(1).truncationMode(.tail)
                }
                .font(CaploFont.caption).foregroundStyle(CaploColor.warning)
                .padding(.horizontal, CaploMetrics.Spacing.m).frame(height: 24)
                .caploMaterial(.floating, cornerRadius: 12)
            }
            FloatingBar {
                Button { StudioWindows.hideRecordBar(); StudioWindows.showRecorder() } label: { Image(systemName: "xmark") }
                    .buttonStyle(StudioIconButtonStyle(size: .small)).help("返回录制方式").accessibilityLabel("返回录制方式")
                    .keyboardShortcut(.cancelAction)
                modeGlyph
                settingsDropdown
                cameraDropdown
                microphoneDropdown
                systemAudioDropdown
                FloatingBarDivider()
                RecordButton { model.start() }.disabled(!model.canStart)
            }
        }
        .padding(.horizontal, CaploMetrics.floatingBarInset)
        .padding(.bottom, CaploMetrics.floatingBarInset)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .bottom)
        // 选中麦克风即开始试听；开关、设备一变就同步。
        .onAppear { model.syncMicrophoneMonitor() }
        .onChange(of: microphone) { model.syncMicrophoneMonitor() }
        .onChange(of: microphoneID) { model.syncMicrophoneMonitor() }
        .foregroundStyle(CaploColor.textPrimary)
        .tint(CaploColor.accent)
        .preferredColorScheme(.dark)
        .task { refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in refreshDevices() }
    }

    /// 当前录制方式的图标，只作状态提示；悬停显示来源名称。
    private var modeGlyph: some View {
        Image(systemName: model.mode.symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(CaploColor.textSecondary)
            .frame(width: CaploMetrics.ControlHeight.medium, height: CaploMetrics.ControlHeight.medium)
            .help("\(model.mode.rawValue) · \(model.sourceTitle)")
            .accessibilityLabel("\(model.mode.rawValue)录制，来源 \(model.sourceTitle)")
    }

    private var settingsDropdown: some View {
        IconDropdown(symbol: "gearshape", accessibilityName: "录制设置", help: "来源与录制设置 · \(model.sourceTitle)") {
            Section(model.mode == .window ? "窗口" : "显示器") {
                ForEach(model.sources) { source in
                    Button { model.choose(source) } label: {
                        Label(source.title, systemImage: source.id == model.source?.id ? "checkmark" : model.mode.symbol)
                    }
                }
                if model.mode == .region { Button("重新框选区域…") { Task { await model.pickRegion() } } }
                if model.mode == .window { Button("在屏幕上选择窗口…") { Task { await model.pickWindow() } } }
                Button("刷新来源") { Task { await model.refreshSources() } }
            }
            Section("录制") {
                Menu("倒计时 · " + (countdown == 0 ? "关" : "\(countdown) 秒")) {
                    ForEach([0, 3, 5, 10], id: \.self) { seconds in
                        choice(seconds == 0 ? "不倒计时" : "\(seconds) 秒", selected: countdown == seconds) { countdown = seconds }
                    }
                }
                Menu("帧率 · \(frameRate) fps") {
                    ForEach([30, 60], id: \.self) { rate in choice("\(rate) fps", selected: frameRate == rate) { frameRate = rate } }
                }
            }
            Divider()
            Button("更多设置…") { StudioWindows.showSettings() }
        }
        .environment(\.colorScheme, .dark)
    }

    private var cameraDropdown: some View {
        SourceDropdown(symbol: "video", offSymbol: "video.slash",
                       title: camera ? RecordingDeviceNames.camera(id: cameraID, cameras: cameras) : "摄像头 关",
                       isOff: !camera, accessibilityName: "摄像头", maxTitleWidth: 140) {
            choice("关闭", selected: !camera) { camera = false }
            choice("系统默认摄像头", selected: camera && cameraID.isEmpty) { camera = true; cameraID = "" }
            if !cameras.isEmpty { Divider() }
            ForEach(cameras) { device in
                choice(device.name, selected: camera && cameraID == device.id) { camera = true; cameraID = device.id }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var microphoneDropdown: some View {
        SourceDropdown(symbol: "mic", offSymbol: "mic.slash",
                       title: microphone ? RecordingDeviceNames.microphone(id: microphoneID, devices: devices) : "麦克风 关",
                       isOff: !microphone, accessibilityName: "麦克风", maxTitleWidth: 140,
                       leading: microphone && MicrophoneMonitor.shared.active ? AnyView(MicrophoneActivityIcon(level: MicrophoneMonitor.shared.level)) : nil) {
            choice("关闭", selected: !microphone) { microphone = false }
            choice("系统默认输入", selected: microphone && microphoneID.isEmpty) { microphone = true; microphoneID = "" }
            if !devices.isEmpty { Divider() }
            ForEach(devices) { device in
                choice(device.name, selected: microphone && microphoneID == device.id) { microphone = true; microphoneID = device.id }
            }
            Divider()
            // 麦克风模式（语音隔离等）只能由用户在系统面板里选；回声消除与降噪在编辑器的声音面板里离线做。
            Text("麦克风模式 · " + MicrophoneModes.shared.currentName)
            Button("更改麦克风模式…") { MicrophoneModes.showSystemPicker() }
        }
        .environment(\.colorScheme, .dark)
    }

    private var systemAudioDropdown: some View {
        SourceDropdown(symbol: "speaker.wave.2", offSymbol: "speaker.slash",
                       title: systemAudio ? RecordingDeviceNames.systemAudio(scope: scope, selected: selectedApplications, applications: applications) : "系统声音 关",
                       isOff: !systemAudio, accessibilityName: "系统声音", maxTitleWidth: 150) {
            choice("关闭", selected: !systemAudio) { systemAudio = false }
            choice("全部系统声音", selected: systemAudio && scope == "all") { systemAudio = true; scope = "all" }
            choice("仅指定应用…", selected: systemAudio && scope == "applications") {
                systemAudio = true; scope = "applications"; applications = AudioInputCatalog.applications(); choosingApplications = true
            }
        }
        // 只为原生菜单采用浅字外观；不改变录制条根部保存的通透 / 深色偏好。
        .environment(\.colorScheme, .dark)
        .popover(isPresented: $choosingApplications, arrowEdge: .top) {
            SystemAudioApplicationPicker { choosingApplications = false }
        }
    }

    /// 菜单里的单选项：用 Toggle 让系统画原生勾选标记，不再给未选中项传空的符号名（会刷 "No symbol named ''" 日志）。
    /// 点已选中的项保持选中，不会取消。
    private func choice(_ title: String, selected: Bool, select: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { selected }, set: { if $0 { select() } }))
    }

    private func refreshDevices() {
        devices = AudioInputCatalog.microphones()
        cameras = CameraInputCatalog.cameras()
        applications = AudioInputCatalog.applications()
    }
}

/// 试听中的麦克风图标：绿色话筒随电平轻微放大，右侧三根绿色音波柱按电平跳动，没有声音时缩成小点。
struct MicrophoneActivityIcon: View {
    let level: Float
    private static let weights: [Float] = [0.6, 1, 0.75]
    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(CaploColor.live)
                .scaleEffect(1 + CGFloat(min(1, max(0, level))) * 0.12)
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule().fill(CaploColor.live)
                        .frame(width: 2, height: 2 + CGFloat(min(1, max(0, level)) * Self.weights[index]) * 9)
                }
            }
        }
        .frame(width: CaploMetrics.Icon.control + 12)
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityLabel("麦克风试听中")
    }
}

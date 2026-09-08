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
    @AppStorage("recording.cameraFormat") private var cameraFormat = ""
    @AppStorage("recording.microphoneDeviceID") private var microphoneID = ""
    @AppStorage("recording.systemAudioScope") private var scope = "all"
    @AppStorage("recording.systemAudioApplications") private var applicationData = Data()
    @AppStorage("recording.countdown") private var countdown = 3
    @AppStorage("recording.frameRate") private var frameRate = 60
    @State private var devices: [CaptureMicrophone] = []
    @State private var cameras: [CaptureCamera] = []
    @State private var cameraFormats: [CameraFormat] = []
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
        .onAppear { model.syncMicrophoneMonitor(); model.syncCameraMonitor() }
        .onChange(of: microphone) { model.syncMicrophoneMonitor() }
        .onChange(of: microphoneID) { model.syncMicrophoneMonitor() }
        .onChange(of: camera) { model.syncCameraMonitor() }
        .onChange(of: cameraID) { refreshCameraFormats(); model.syncCameraMonitor() }
        .onChange(of: cameraFormat) { model.syncCameraMonitor() }
        .foregroundStyle(CaploColor.textPrimary)
        .tint(CaploColor.accent)
        .preferredColorScheme(.dark)
        .task { refreshDevices() }
        // 设备插拔：刷新列表，试听与画中画按可用性重新同步（设备回来自动接上，拔掉自动撤下）。
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { deviceChanged($0, connected: true) }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { deviceChanged($0, connected: false) }
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
            var entries: [PopupMenuEntry] = [.header(model.mode == .window ? "窗口" : "显示器")]
            entries += model.sources.map { source in .item(source.title, checked: source.id == model.source?.id) { model.choose(source) } }
            if model.mode == .region { entries.append(.item("重新框选区域…") { Task { await model.pickRegion() } }) }
            if model.mode == .window { entries.append(.item("在屏幕上选择窗口…") { Task { await model.pickWindow() } }) }
            entries.append(.item("刷新来源") { Task { await model.refreshSources() } })
            entries += [
                .separator, .header("录制"),
                .submenu("倒计时 · " + (countdown == 0 ? "关" : "\(countdown) 秒"), [0, 3, 5, 10].map { seconds in
                    choice(seconds == 0 ? "不倒计时" : "\(seconds) 秒", selected: countdown == seconds) { countdown = seconds }
                }),
                .submenu("帧率 · \(frameRate) fps", [30, 60].map { rate in choice("\(rate) fps", selected: frameRate == rate) { frameRate = rate } }),
                .separator,
                .item("更多设置…") { StudioWindows.showSettings() },
            ]
            return entries
        }
    }

    // 所选设备不在线就按"关"显示（不出现"未连接"这种中间态），设备回来自动恢复。
    private var cameraTitle: String? { camera ? RecordingDeviceNames.camera(id: cameraID, cameras: cameras) : nil }
    private var microphoneTitle: String? { microphone ? RecordingDeviceNames.microphone(id: microphoneID, devices: devices) : nil }

    private var cameraDropdown: some View {
        SourceDropdown(symbol: "video", offSymbol: "video.slash",
                       title: cameraTitle ?? "摄像头 关",
                       isOff: cameraTitle == nil, accessibilityName: "摄像头", maxTitleWidth: 140) {
            var entries: [PopupMenuEntry] = [
                choice("关闭", selected: !camera) { camera = false },
                choice("默认摄像头", selected: camera && cameraID.isEmpty) { camera = true; cameraID = "" },
            ]
            if !cameras.isEmpty { entries.append(.separator) }
            entries += cameras.map { device in choice(device.name, selected: camera && cameraID == device.id) { camera = true; cameraID = device.id } }
            if !cameraFormats.isEmpty {
                // 设备真实支持的格式（尺寸 × 帧率）全列出来；预览与录制共用同一个选择。
                let effective = CameraFormat.resolve(available: cameraFormats, wanted: CameraFormat(key: cameraFormat))
                entries += [.separator, .submenu("分辨率 · " + (effective?.title ?? "自动"), cameraFormats.map { format in
                    choice(format.title, selected: format == effective) { cameraFormat = format.key }
                })]
            }
            return entries
        }
    }

    private var microphoneDropdown: some View {
        // 试听时的跳动图标就在按钮标签里：标签是普通视图，图标自己观察电平刷新，录制条主体不因电平重绘。
        SourceDropdown(symbol: "mic", offSymbol: "mic.slash",
                       title: microphoneTitle ?? "麦克风 关",
                       isOff: microphoneTitle == nil, accessibilityName: "麦克风", maxTitleWidth: 140,
                       leading: microphone && MicrophoneMonitor.shared.active ? AnyView(MicrophoneMonitorIcon()) : nil) {
            var entries: [PopupMenuEntry] = [
                choice("关闭", selected: !microphone) { microphone = false },
                choice("默认麦克风", selected: microphone && microphoneID.isEmpty) { microphone = true; microphoneID = "" },
            ]
            if !devices.isEmpty { entries.append(.separator) }
            entries += devices.map { device in choice(device.name, selected: microphone && microphoneID == device.id) { microphone = true; microphoneID = device.id } }
            // 麦克风模式（语音隔离等）只能由用户在系统面板里选；回声消除与降噪在编辑器的声音面板里离线做。
            entries += [.separator, .text("麦克风模式 · " + MicrophoneModes.shared.currentName), .item("更改麦克风模式…") { MicrophoneModes.showSystemPicker() }]
            return entries
        }
    }

    private var systemAudioDropdown: some View {
        SourceDropdown(symbol: "speaker.wave.2", offSymbol: "speaker.slash",
                       title: systemAudio ? RecordingDeviceNames.systemAudio(scope: scope, selected: selectedApplications, applications: applications) : "系统声音 关",
                       isOff: !systemAudio, accessibilityName: "系统声音", maxTitleWidth: 150) { [
            choice("关闭", selected: !systemAudio) { systemAudio = false },
            choice("全部系统声音", selected: systemAudio && scope == "all") { systemAudio = true; scope = "all" },
            choice("仅指定应用…", selected: systemAudio && scope == "applications") {
                systemAudio = true; scope = "applications"; applications = AudioInputCatalog.applications(); choosingApplications = true
            },
        ] }
        .popover(isPresented: $choosingApplications, arrowEdge: .top) {
            SystemAudioApplicationPicker { choosingApplications = false }
        }
    }

    /// 菜单里的单选项：选中的画原生勾选标记。
    private func choice(_ title: String, selected: Bool, select: @escaping @MainActor () -> Void) -> PopupMenuEntry {
        .item(title, checked: selected, action: select)
    }

    /// 只在列表真的变了才写状态：录制条整体重绘会让打开着的下拉菜单收起。
    private func refreshDevices() {
        let microphones = AudioInputCatalog.microphones()
        if microphones != devices { devices = microphones }
        let videoDevices = CameraInputCatalog.cameras()
        if videoDevices != cameras { cameras = videoDevices }
        refreshCameraFormats()
        let running = AudioInputCatalog.applications()
        if running != applications { applications = running }
    }

    private func refreshCameraFormats() {
        let formats = CameraInputCatalog.formats(for: cameraID.isEmpty ? nil : cameraID)
        if formats != cameraFormats { cameraFormats = formats }
    }

    /// 录制中设备变化由录制器自己处理（它借用着试听与预览），这里不刷新也不同步；录制条没显示着也不刷新
    /// （收起录制条停掉试听 / 预览会引来一串设备通知，枚举设备是同步的，别让它拖慢切换）。
    private func deviceChanged(_ note: Notification, connected: Bool) {
        NSLog("Caplo：设备%@：%@", connected ? "接入" : "拔出", (note.object as? AVCaptureDevice)?.localizedName ?? "未知")
        guard !model.recorder.isBusy, StudioWindows.isRecordBarVisible else { return }
        refreshDevices(); model.syncMicrophoneMonitor(); model.syncCameraMonitor()
    }
}

/// 电平单独观察：只有这个图标随音频块刷新，录制条整体不重绘（整体重绘会让打开着的菜单收起）。
private struct MicrophoneMonitorIcon: View {
    var body: some View { MicrophoneActivityIcon(level: MicrophoneMonitor.shared.level) }
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

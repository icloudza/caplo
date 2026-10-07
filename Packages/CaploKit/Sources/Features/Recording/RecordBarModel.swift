import AppKit
import Observation
import CaptureKit

/// 录制条状态：录制方式、来源、区域与启动动作。设备开关与设备偏好由 UserDefaults 持有，
/// 按 REC 时统一读取快照，与录制条显示保持一致。
@MainActor @Observable
public final class RecordBarModel {
    let recorder = ScreenRecorder.shared
    private(set) var mode: RecordingMode
    private(set) var source: CaptureSource?
    private(set) var region: CGRect?
    private(set) var selectingRegion = false
    private(set) var localError: String?

    init(mode: RecordingMode, source: CaptureSource? = nil, region: CGRect? = nil) {
        self.mode = mode; self.source = source; self.region = region
    }

    /// 离屏预览用的静态模型（来源 id 为 preview）：不枚举来源，也不启动麦克风试听。
    var isPreview: Bool { source?.id == "preview" }

    /// 偏好里打开且所选设备在线才算"有效开启"：设备不在线一律当关闭（界面显示"关"，不试听、不预览、录制时不带）。
    static func microphoneEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "recording.microphone") && RecordingDeviceNames.available(id: defaults.string(forKey: "recording.microphoneDeviceID") ?? "", in: AudioInputCatalog.microphones().map(\.id))
    }
    static func cameraEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "recording.camera") && RecordingDeviceNames.available(id: defaults.string(forKey: "recording.cameraDeviceID") ?? "", in: CameraInputCatalog.cameras().map(\.id))
    }

    /// 选中麦克风就开始试听（只算电平不写盘、不回放）：方便调整设备与系统麦克风模式；录制中或预览模型不试听。
    func syncMicrophoneMonitor(defaults: UserDefaults = .standard) {
        // 录制中采集归录制器（它正借用着试听），这里不动；录制条没显示着（关掉了、临时收起）也不动——
        // 录制条视图在窗口收起后仍活着，设置页开关与设备插拔都会经过它，不能把已经退出的试听重新拉起来。
        guard !recorder.isBusy, StudioWindows.isRecordBarVisible else { return }
        guard !isPreview, Self.microphoneEnabled(defaults: defaults) else { MicrophoneMonitor.shared.stop(); return }
        let id = defaults.string(forKey: "recording.microphoneDeviceID") ?? ""
        MicrophoneMonitor.shared.start(deviceID: id.isEmpty ? nil : id)
    }

    /// 摄像头有效开启就起预览会话并在屏幕上显示画中画；关掉、设备不在线或离开录制流程撤下。录制中或预览模型不起。
    func syncCameraMonitor(defaults: UserDefaults = .standard) {
        guard !recorder.isBusy, StudioWindows.isRecordBarVisible else { return }
        if !isPreview, Self.cameraEnabled(defaults: defaults) {
            let id = defaults.string(forKey: "recording.cameraDeviceID") ?? ""
            CameraMonitor.shared.start(deviceID: id.isEmpty ? nil : id, format: CameraFormat(key: defaults.string(forKey: "recording.cameraFormat")))
        } else {
            CameraMonitor.shared.stop()
        }
        CameraPreviewCoordinator.refresh()
    }

    /// 当前方式下可选的来源。
    var sources: [CaptureSource] { recorder.sources.filter { $0.kind == mode.kind } }
    var sourceTitle: String { source?.title ?? mode.sourcePlaceholder }
    var errorMessage: String? { localError ?? recorder.errorMessage }
    var canStart: Bool {
        source != nil && !recorder.isBusy && !selectingRegion && (mode != .region || region != nil)
    }
    /// 录制条贴在所选来源所在显示器的底部：显示器按编号，窗口按其中心点所在屏幕；找不到时用主显示器。
    var targetScreen: NSScreen? {
        if let displayID = source?.displayID {
            return NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
            } ?? NSScreen.main
        }
        if source?.kind == .window, let frame = source?.frame {
            let rect = WindowGeometry.appKitRect(fromGlobal: frame)
            return NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) } ?? NSScreen.main
        }
        return NSScreen.main
    }

    /// 重新枚举来源；已选来源消失时回退到第一个，全屏默认主显示器。
    func refreshSources() async {
        await recorder.refreshSources()
        if let source, sources.contains(where: { $0.id == source.id }) { return }
        source = sources.first(where: { $0.displayID == CGMainDisplayID() }) ?? sources.first
        if mode == .region { region = nil }
    }

    /// 下拉里选来源；窗口模式下把该窗口的应用带到最前。
    func choose(_ newSource: CaptureSource) {
        guard newSource.id != source?.id else { return }
        source = newSource
        localError = nil
        if mode == .region { region = nil }
        if mode == .display, let screen = targetScreen { RecordingFrameSession.begin(on: screen) }
        focusSourceApplication()
    }

    /// 用户切换到别的应用后，窗口高亮会话把目标换成该应用最前面的窗口；不在来源列表里就重新枚举一次。
    func adoptFrontmost(windowID: UInt32) async {
        guard mode == .window else { return }
        if let found = sources.first(where: { $0.windowID == windowID }) { source = found; localError = nil; return }
        await recorder.refreshSources()
        guard mode == .window, let found = sources.first(where: { $0.windowID == windowID }) else { return }
        source = found; localError = nil
    }

    /// 把所选窗口的应用激活并将其全部窗口带到最前，让用户看到虚线框住的就是将要录制的窗口。
    /// 只在本应用处于最前时有效（协作式激活），因此要在录制条显示之后调用。
    func focusSourceApplication() {
        guard mode == .window, let pid = source?.processID, pid != ProcessInfo.processInfo.processIdentifier,
              let application = NSRunningApplication(processIdentifier: pid), !application.isActive else { return }
        if !application.activate(from: .current, options: [.activateAllWindows]) {
            application.activate(options: [.activateAllWindows])
        }
    }

    /// 区域覆盖层的移动 / 调整实时同步到这里；显示器变化时一并更新来源。
    func updateRegion(_ rect: CGRect, display: CaptureSource?) {
        region = rect; localError = nil
        if let display, display.id != source?.id { source = display }
    }

    /// 区域模式：清空当前框重新拖一次（覆盖层保留）。
    func pickRegion() async {
        StudioWindows.beginRegionSelection(reset: true)
    }

    /// 窗口模式：隐藏录制条，在屏幕上悬停点选另一个窗口；取消保留当前窗口。
    func pickWindow() async {
        selectingRegion = true
        StudioWindows.hideRecordBar(stopMonitors: false)
        await recorder.refreshSources()
        let picked = await WindowPicker.pick(from: recorder.sources)
        selectingRegion = false
        if let picked { source = picked; localError = nil }
        StudioWindows.showRecordBar(self, focusTarget: picked != nil)
    }

    /// 按 REC：读取设备偏好快照，收起准备窗口，进入倒计时；启动失败回到录制条。
    func start() {
        guard let source, canStart else { return }
        var options = RecordingOptions()
        let defaults = UserDefaults.standard
        options.microphone = defaults.bool(forKey: "recording.microphone")
        options.systemAudio = defaults.bool(forKey: "recording.systemAudio")
        options.capturePointer = true
        // 录制始终单独保存真实光标轨迹并从画面里排除光标；编辑器里再决定画成哪种样式。不再提供"系统光标"模式。
        options.reconstructCursor = true
        options.countdown = max(0, min(10, defaults.object(forKey: "recording.countdown") as? Int ?? 3))
        options.frameRate = Double(max(24, min(120, defaults.object(forKey: "recording.frameRate") as? Int ?? 60)))
        options.region = mode == .region ? region : nil
        RecordingAudioPreferences.apply(to: &options)
        RecordingCameraPreferences.apply(to: &options)
        // 所选设备不在线就不带这路输入，而不是报错拦住录制。
        if options.microphone, !Self.microphoneEnabled(defaults: defaults) { options.microphone = false }
        if options.camera, !Self.cameraEnabled(defaults: defaults) { options.camera = false }
        // 打开着麦克风 / 摄像头但权限被拒过：系统不会再弹询问框，直接带用户去权限窗口里那一行。
        if PermissionsWindow.enforced {
            let center = PermissionCenter.shared
            center.refresh()
            if options.microphone, center.status(.microphone) == .denied { PermissionsWindow.shared.show(.standalone, focus: .microphone); return }
            if options.camera, center.status(.camera) == .denied { PermissionsWindow.shared.show(.standalone, focus: .camera); return }
        }
        guard StudioWindows.prepareForRecording() else { return }
        localError = nil
        // 试听与预览不停：录制器直接借用正在跑的麦克风采集与摄像头会话（只加写盘出口），设备从打开到录完一直亮着。
        let previous = recorder.completedURL
        Task {
            await recorder.start(sourceID: source.id, options: options)
            if Self.shouldReturnToBar(busy: recorder.isBusy, completed: recorder.completedURL, before: previous) { StudioWindows.showRecordBar(self) }
        }
    }

    /// 开始录制之后要不要把录制条放回来：没在录、也没有产出新的工程（产出了就交给编辑器打开）。
    /// 不能只看 `completedURL == nil`：它保留着上一段录制的结果，开始在前置检查就退出时它不会被清空，
    /// 以前这种情况下准备窗口已经藏起来、录制条又不回来，屏幕上什么都没有，错误也看不到。
    static func shouldReturnToBar(busy: Bool, completed: URL?, before previous: URL?) -> Bool {
        guard !busy else { return false }
        return completed == nil || completed == previous
    }

    /// 离屏预览用的静态模型，不枚举真实来源。
    public static func preview(mode: String = String(localized: "全屏"), sourceTitle: String = String(localized: "主显示器")) -> RecordBarModel {
        let mode = RecordingMode(rawValue: mode) ?? .display
        return RecordBarModel(mode: mode, source: CaptureSource(id: "preview", title: sourceTitle, kind: mode.kind))
    }
}

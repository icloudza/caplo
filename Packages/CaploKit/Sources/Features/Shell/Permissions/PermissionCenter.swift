import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import Speech
import UserNotifications
import ExportKit

/// Caplo 用到的系统权限。点击与指针轨迹只用鼠标全局监听，不需要辅助功能权限，这里不列。
enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case screen, microphone, camera, speech, notifications
    var id: Self { self }

    var title: String {
        switch self {
        case .screen: String(localized: "屏幕录制"); case .microphone: String(localized: "麦克风"); case .camera: String(localized: "摄像头"); case .speech: String(localized: "语音识别")
        case .notifications: String(localized: "通知")
        }
    }

    var purpose: String {
        switch self {
        case .screen: String(localized: "录制屏幕与窗口画面")
        case .microphone: String(localized: "录制讲解声音")
        case .camera: String(localized: "录制人像画中画")
        case .speech: String(localized: "在本机转写字幕")
        case .notifications: String(localized: "有新版本时提醒")
        }
    }

    var symbol: String {
        switch self {
        case .screen: "rectangle.dashed.badge.record"; case .microphone: "mic"; case .camera: "video"; case .speech: "captions.bubble"; case .notifications: "bell"
        }
    }

    /// 只有屏幕录制是必需的；其余在用户打开对应功能时才需要。
    var required: Bool { self == .screen }

    /// 系统设置"隐私与安全性"里对应面板的锚点。
    var settingsAnchor: String {
        switch self {
        case .screen: "Privacy_ScreenCapture"; case .microphone: "Privacy_Microphone"
        case .camera: "Privacy_Camera"; case .speech: "Privacy_SpeechRecognition"
        case .notifications: ""
        }
    }
}

enum PermissionStatus: Equatable, Sendable {
    case granted
    /// 还没问过：可以直接弹系统询问框。
    case notDetermined
    /// 拒绝过或被管理策略限制：只能到系统设置里开。
    /// 屏幕录制请求过但没生效也算这一档：开关打开后要重新打开应用才查得到，这之前分不清"拒绝"与"已打开待重启"。
    case denied
    /// 预检已通过但仍读不到屏幕（开关已打开、应用还没重新打开）：只差重新打开 Caplo。
    case needsRelaunch
}

/// 权限的唯一来源：查询不弹窗，请求按系统规则走（未询问 → 系统询问框；已拒绝 → 系统设置）。
///
/// 屏幕录制的判断参照成熟录屏应用的做法：`CGPreflightScreenCaptureAccess()` 不弹窗但可能停在启动时的旧值，
/// 所以它为真之后再在后台读一次 `SCShareableContent` 确认（限时 4 秒、失败至少隔 5 秒再试、成功即缓存到进程结束）；
/// 绝不在主线程同步等它，授权后到重启前 replayd 可能一直不返回。
@MainActor @Observable
final class PermissionCenter {
    static let shared = PermissionCenter()
    static let screenRequestedKey = "permissions.screenRequested"
    /// 启动引导是否已走完（点过"开始使用"或"稍后"）。没走完时每次启动都显示，包括系统为屏幕录制授权重启应用之后。
    static let onboardingDoneKey = "permissions.onboardingDone"

    private(set) var statuses: [PermissionKind: PermissionStatus] = [:]

    @ObservationIgnored private var screenConfirmed = false
    @ObservationIgnored private var screenProbe: Task<Void, Never>?
    @ObservationIgnored private var lastScreenProbe = Date.distantPast
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    /// 离屏预览用：固定一组状态，不查询系统。
    init(preview: [PermissionKind: PermissionStatus]) { statuses = preview }
    private init() { refresh() }

    func status(_ kind: PermissionKind) -> PermissionStatus { statuses[kind] ?? .notDetermined }
    var screenGranted: Bool { status(.screen) == .granted }

    // MARK: 查询

    func refresh() {
        statuses[.microphone] = Self.captureStatus(.audio)
        statuses[.camera] = Self.captureStatus(.video)
        statuses[.speech] = switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
        statuses[.screen] = screenStatus()
        refreshNotifications()
    }

    /// 通知权限只能异步读：读到后再更新这一行。测试与离屏预览进程里通知中心不可用，不读。
    private func refreshNotifications() {
        guard PermissionsWindow.enforced else { return }
        Task { [weak self] in
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            self?.statuses[.notifications] = switch status {
            case .authorized, .provisional: .granted
            case .notDetermined: .notDetermined
            default: .denied
            }
        }
    }

    private static func captureStatus(_ media: AVMediaType) -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    private func screenStatus() -> PermissionStatus {
        if screenConfirmed { return .granted }
        guard CGPreflightScreenCaptureAccess() else {
            // 预检为假：从没请求过就是"未询问"，否则只能去系统设置（打开后由系统或用户重新打开应用）。
            return UserDefaults.standard.bool(forKey: Self.screenRequestedKey) ? .denied : .notDetermined
        }
        probeScreenContent()
        // 后台确认回来之前按已授权显示：预检为真时绝大多数情况就是真授权。
        return .granted
    }

    /// 预检为真后在后台确认一次能读到显示器；失败则视为需要重新打开。
    private func probeScreenContent() {
        guard screenProbe == nil, Date().timeIntervalSince(lastScreenProbe) > 5 else { return }
        lastScreenProbe = Date()
        screenProbe = Task { [weak self] in
            let ok = await Self.canReadShareableContent()
            guard let self else { return }
            self.screenProbe = nil
            if ok {
                self.screenConfirmed = true
                self.statuses[.screen] = .granted
            } else {
                self.statuses[.screen] = .needsRelaunch
            }
        }
    }

    nonisolated private static func canReadShareableContent() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                (try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true))?.displays.isEmpty == false
            }
            group.addTask { try? await Task.sleep(for: .seconds(4)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// 来源读取失败、预检却说已授权：授权后还没重新打开应用。
    static var onboardingDone: Bool {
        get { UserDefaults.standard.bool(forKey: onboardingDoneKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardingDoneKey) }
    }

    /// 应用在系统里显示的名字（调试版是 "Caplo Dev"），文案里指向系统设置的那一项用它。
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Caplo"
    }

    func markScreenNeedsRelaunch() {
        screenConfirmed = false
        statuses[.screen] = .needsRelaunch
    }

    // MARK: 请求

    /// 按钮动作：未询问 → 弹系统询问框；已拒绝 → 打开系统设置对应面板；需要重启 → 重新打开 Caplo。
    func request(_ kind: PermissionKind) {
        switch status(kind) {
        case .granted: return
        case .needsRelaunch: Self.relaunch()
        case .denied: openSettings(kind)
        case .notDetermined:
            // 隐藏 Dock 图标时应用是 .accessory，系统询问框可能出现在别的应用后面：先激活。
            NSApp.activate(ignoringOtherApps: true)
            switch kind {
            case .screen:
                UserDefaults.standard.set(true, forKey: Self.screenRequestedKey)
                // macOS 15 起 CGRequestScreenCaptureAccess 不可靠：读一次可共享内容来触发系统询问框。
                // 询问框弹出的同时这次读取就会失败，不能据此判"拒绝"；状态由轮询按预检结果更新。
                Task { _ = await Self.canReadShareableContent() }
                statuses[.screen] = .denied
            case .microphone, .camera:
                Task { [weak self] in
                    _ = await AVCaptureDevice.requestAccess(for: kind == .microphone ? .audio : .video)
                    self?.refresh()
                }
            case .notifications:
                Task { [weak self] in
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    self?.refresh()
                }
            case .speech:
                // 系统在后台队列回调授权结果；这里的闭包若写在主线程隔离的方法里会被推断为主线程隔离，
                // 回调一到就触发运行时队列断言崩溃。改用不隔离的异步封装，回到主线程再刷新。
                Task { [weak self] in
                    _ = await SpeechTranscriber.requestPermission()
                    self?.refresh()
                }
            }
        }
    }

    func openSettings(_ kind: PermissionKind) {
        // 通知不在"隐私与安全性"里，有自己的设置面板（按应用定位）。
        if kind == .notifications {
            let id = Bundle.main.bundleIdentifier ?? ""
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") { NSWorkspace.shared.open(url) }
            return
        }
        // macOS 13 起的新地址优先，打不开再用旧地址；两者锚点相同。
        let urls = ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(kind.settingsAnchor)",
                    "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsAnchor)"]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { break }
        }
    }

    /// 屏幕录制授权要重新打开应用才生效：启动一个新实例，再退出当前实例（正常退出流程会先保存编辑）。
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 等当前进程退出后再打开，避免系统把"打开"当成激活已在运行的实例。
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: 轮询

    /// 权限窗口显示期间每秒刷新一次，应用重新激活时也刷新：用户从系统设置回来时状态立即更新。
    func startWatching() {
        refresh()
        if pollTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { PermissionCenter.shared.refresh() } }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PermissionCenter.shared.refresh() }
            }
        }
    }

    func stopWatching() {
        pollTimer?.invalidate(); pollTimer = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver); self.activationObserver = nil }
    }
}

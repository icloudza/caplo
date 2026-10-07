import AppKit
import Sparkle

/// 在线更新的唯一入口：持有 Sparkle 的 `SPUUpdater`，向菜单与设置页暴露开关和状态。
///
/// 安装包下载、EdDSA 签名校验、替换应用与重启都由 Sparkle 完成；本模块只负责界面与时机。
/// 发布包的 Info.plist 带 `SUFeedURL` 与 `SUPublicEDKey`（由发布流水线写入），两者缺一不启动——
/// 开发构建、测试进程与离屏预览都不会去联网检查，也不可能被线上版本替换掉。
@MainActor @Observable
public final class AppUpdater: NSObject, SPUUpdaterDelegate {
    public static let shared = AppUpdater()

    let flow = UpdateFlow()
    /// Sparkle 已成功启动；false 时菜单与设置不显示更新入口的操作。
    private(set) var isEnabled = false
    /// 现在能不能发起检查（后台下载中时为 false）。
    private(set) var canCheck = false
    private(set) var lastCheck: Date?
    private(set) var automaticallyChecks = true
    private(set) var automaticallyDownloads = false

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private lazy var driver = UpdateDriver(flow: flow)
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    override private init() { super.init() }

    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let key = (info["SUPublicEDKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return Bundle.main.bundleURL.pathExtension == "app" && feed.hasPrefix("https://") && !key.isEmpty
    }

    /// 启动时调用一次。配置不全或启动失败只记日志，不影响录制与编辑。
    public func start() {
        guard updater == nil, Self.isConfigured else { return }
        flow.retryCheck = { [weak self] in self?.checkForUpdates() }
        flow.close = { UpdateWindow.shared.hide() }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do {
            try updater.start()
        } catch {
            NSLog("Caplo 在线更新未启动：%@", error.localizedDescription)
            return
        }
        self.updater = updater
        isEnabled = true
        canCheck = updater.canCheckForUpdates
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
        }
        syncSettings()
    }

    /// 菜单与设置里的"检查更新"。会话进行中（例如推迟着的提醒、正在下载）时 Sparkle 会改为把那个会话带到前面。
    public func checkForUpdates() {
        guard let updater else { return }
        updater.checkForUpdates()
    }

    func setAutomaticallyChecks(_ value: Bool) {
        updater?.automaticallyChecksForUpdates = value
        syncSettings()
    }

    func setAutomaticallyDownloads(_ value: Bool) {
        updater?.automaticallyDownloadsUpdates = value
        syncSettings()
    }

    /// 有新版本等着用户处理：窗口显示着新版本，或录制中推迟了提醒。菜单据此把"检查更新"换成"安装新版本"。
    var pendingVersion: String? {
        if let deferred = flow.deferredVersion { return deferred }
        if case .available = flow.phase { return flow.release?.version }
        if case .ready = flow.phase { return flow.release?.version }
        return nil
    }

    private func syncSettings() {
        guard let updater else { return }
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
        lastCheck = updater.lastUpdateCheckDate
    }

    func driverIdleTick() { driver.idleTick() }

    // MARK: SPUUpdaterDelegate

    public func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastCheck = updater.lastUpdateCheckDate
    }
}

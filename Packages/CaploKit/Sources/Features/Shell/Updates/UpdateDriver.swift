import AppKit
import Sparkle
import CaptureKit

/// Sparkle 的界面驱动：把回调翻成 `UpdateFlow` 的阶段，并决定更新窗口什么时候出现。
///
/// - 用户点的检查：立即显示并激活应用。
/// - 后台定时检查发现新版本：录制、倒计时或导出期间不弹窗，推迟到空闲后再出现；出现时不抢焦点。
/// - 后台自动下载好的更新：Sparkle 会在退出时静默安装，这里只在它要求时提示重启。
@MainActor
final class UpdateDriver: NSObject, SPUUserDriver {
    let flow: UpdateFlow
    /// 推迟中的后台提醒；空闲后执行，或用户主动打开更新时立即执行。
    private var deferred: (() -> Void)?
    private var idleTimer: Timer?

    init(flow: UpdateFlow) { self.flow = flow }

    /// 录制（含倒计时、启动、收尾）或导出进行中：不打断。
    static var isBusy: Bool { ScreenRecorder.shared.isBusy || VideoEditorSessions.current?.exporting == true }

    // MARK: 检查

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Info.plist 已开启自动检查，正常不会走到这里；万一走到，按默认开启自动检查、不发送系统信息。
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        deferred = nil; stopIdleWatch()
        flow.beginChecking(cancel: cancellation)
        UpdateWindow.shared.present(activate: true)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let release = UpdateRelease(item: appcastItem)
        let offer = { [flow] in
            flow.offer(release, downloaded: state.stage != .notDownloaded, userInitiated: state.userInitiated) { choice in
                switch choice {
                case .install: reply(.install)
                case .later: reply(.dismiss)
                case .skip: reply(.skip)
                }
            }
        }
        if state.userInitiated {
            offer()
            UpdateWindow.shared.present(activate: true)
        } else {
            presentWhenIdle(version: release.version) { offer(); UpdateWindow.shared.present(activate: false) }
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // 说明放在单独的页面（releaseNotesLink）时由 Sparkle 下载后送到这里；内嵌说明不会走这条路。
        guard let release = flow.release, release.notes.isEmpty else { return }
        let text = downloadData.mimeType?.contains("html") == false
            ? String(decoding: downloadData.data, as: UTF8.self) : UpdateRelease.html(downloadData.data)
        var updated = release
        updated.notes = text
        flow.replaceNotes(of: updated)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        flow.upToDate(Self.notFoundCaption(error, current: flow.currentVersion), acknowledge: acknowledgement)
        UpdateWindow.shared.present(activate: true)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        // 后台检查失败（多半是没网）不打扰；用户点的检查或正在进行的安装才提示。
        guard let message = UpdateErrorText.message(for: error), flow.userInitiated || UpdateWindow.shared.isVisible else {
            acknowledgement(); flow.reset(); UpdateWindow.shared.hide(); return
        }
        flow.fail(message, acknowledge: acknowledgement)
        UpdateWindow.shared.present(activate: flow.userInitiated)
    }

    // MARK: 下载与安装

    func showDownloadInitiated(cancellation: @escaping () -> Void) { flow.beginDownload(cancel: cancellation) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { flow.expectDownload(length: expectedContentLength) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { flow.receive(bytes: length) }
    func showDownloadDidStartExtractingUpdate() { flow.extracting(0) }
    func showExtractionReceivedProgress(_ progress: Double) { flow.extracting(progress) }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        flow.ready { install in reply(install ? .install : .dismiss) }
        // 下载时窗口可能被收起了：就绪后带回来（不抢焦点）。
        if !UpdateWindow.shared.isVisible { presentWhenIdle { UpdateWindow.shared.present(activate: false) } }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        flow.installing(applicationTerminated: applicationTerminated, retry: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        flow.reset()
        UpdateWindow.shared.hide()
    }

    func showUpdateInFocus() {
        // 用户再次点"检查更新"时会话还在：推迟的提醒立即弹出，已显示的窗口拿到前面。
        if let deferred { self.deferred = nil; stopIdleWatch(); deferred() }
        UpdateWindow.shared.present(activate: true)
    }

    func dismissUpdateInstallation() {
        deferred = nil
        stopIdleWatch()
        flow.reset()
        UpdateWindow.shared.hide()
    }

    // MARK: 空闲后再提醒

    /// `version`：推迟期间菜单里提示的版本号。
    private func presentWhenIdle(version: String? = nil, _ action: @escaping () -> Void) {
        guard Self.isBusy else { action(); return }
        deferred = action
        flow.deferredVersion = version ?? flow.release?.version
        guard idleTimer == nil else { return }
        // 录制与导出状态散在几个对象里，轮询比逐个挂观察稳；间隔 3 秒，对后台提醒足够及时。
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { AppUpdater.shared.driverIdleTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    func idleTick() {
        guard !Self.isBusy, let deferred else { return }
        self.deferred = nil
        stopIdleWatch()
        deferred()
    }

    private func stopIdleWatch() { idleTimer?.invalidate(); idleTimer = nil; flow.deferredVersion = nil }

    // MARK: 文案

    static func notFoundCaption(_ error: any Error, current: String) -> String {
        let info = (error as NSError).userInfo
        let reason = (info[SPUNoUpdateFoundReasonKey] as? NSNumber).flatMap { SPUNoUpdateFoundReason(rawValue: $0.int32Value) }
        let latest = info[SPULatestAppcastItemFoundKey] as? SUAppcastItem
        switch reason {
        case .systemIsTooOld:
            if let latest, let minimum = latest.minimumSystemVersion { return String(localized: "\(latest.displayVersionString) 需要 macOS \(minimum) 及以上。") }
            return String(localized: "新版本需要更新的 macOS。")
        case .onNewerThanLatestVersion: return String(localized: "当前版本 \(current)，比已发布的版本更新。")
        default: return String(localized: "当前版本 \(current)。")
        }
    }
}

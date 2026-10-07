import AppKit
import Foundation

/// 更新窗口显示的阶段。由 `UpdateDriver` 按 Sparkle 的回调推进，视图只读。
enum UpdatePhase: Equatable {
    case idle
    /// 用户点了"检查更新"，正在取 appcast。
    case checking
    /// 发现新版本，等用户选择。`downloaded`：安装包已在后台下好，主按钮直接安装。
    case available(downloaded: Bool)
    /// `expected` 为 0 表示服务器没给长度，进度条显示为不定。
    case downloading(received: UInt64, expected: UInt64)
    /// 校验签名、解包。
    case extracting(Double)
    /// 已准备好，等用户决定现在重启还是退出时安装。
    case ready
    /// 已交给安装器；`waitingForQuit`：Caplo 还没退出（例如导出确认里选了继续），可以重试。
    case installing(waitingForQuit: Bool)
    case upToDate(String)
    case failed(String)

    /// 带版本说明的大窗口，还是只有一行状态的小窗口。
    var showsRelease: Bool {
        switch self {
        case .available, .downloading, .extracting, .ready, .installing: true
        case .idle, .checking, .upToDate, .failed: false
        }
    }
}

/// 用户对新版本的选择；和 Sparkle 的 `SPUUserUpdateChoice` 一一对应，界面层不直接引用 Sparkle 类型。
enum UpdateChoice { case install, later, skip }

/// 一次更新会话的界面状态与用户操作。Sparkle 给的回复闭包都存在这里，每个只用一次。
@MainActor @Observable
final class UpdateFlow {
    private(set) var phase: UpdatePhase = .idle
    private(set) var release: UpdateRelease?
    /// 这次是不是用户自己点的检查：决定要不要抢焦点、出错时给不给"重试"。
    private(set) var userInitiated = false
    /// 后台发现、但因录制或导出推迟提醒的版本号。
    var deferredVersion: String?
    let currentVersion: String

    @ObservationIgnored private var respond: ((UpdateChoice) -> Void)?
    @ObservationIgnored private var cancellation: (() -> Void)?
    @ObservationIgnored private var acknowledgement: (() -> Void)?
    @ObservationIgnored private var readyReply: ((Bool) -> Void)?
    @ObservationIgnored private var retryQuit: (() -> Void)?
    /// 用户点了"重试"检查：确认当前错误后由 `AppUpdater` 重新发起。
    @ObservationIgnored var retryCheck: (() -> Void)?
    /// 窗口要求关闭（按钮或红色关闭钮）。
    @ObservationIgnored var close: () -> Void = {}

    init(currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? String(localized: "开发版")) {
        self.currentVersion = currentVersion
    }

    // MARK: 驱动写入

    func beginChecking(cancel: @escaping () -> Void) {
        clearReplies()
        release = nil; userInitiated = true; phase = .checking
        cancellation = cancel
    }

    func offer(_ release: UpdateRelease, downloaded: Bool, userInitiated: Bool, reply: @escaping (UpdateChoice) -> Void) {
        clearReplies()
        self.release = release; self.userInitiated = userInitiated
        phase = .available(downloaded: downloaded)
        respond = reply
    }

    /// 单独下载的更新说明到达后补上；只改说明，不动阶段。
    func replaceNotes(of release: UpdateRelease) {
        guard self.release?.build == release.build else { return }
        self.release = release
    }

    func beginDownload(cancel: @escaping () -> Void) {
        cancellation = cancel
        phase = .downloading(received: 0, expected: release?.size ?? 0)
    }

    func expectDownload(length: UInt64) {
        guard case .downloading(let received, _) = phase else { return }
        phase = .downloading(received: received, expected: length)
    }

    func receive(bytes: UInt64) {
        guard case .downloading(let received, let expected) = phase else { return }
        phase = .downloading(received: received + bytes, expected: expected)
    }

    func extracting(_ progress: Double) {
        cancellation = nil
        phase = .extracting(min(max(progress, 0), 1))
    }

    func ready(reply: @escaping (Bool) -> Void) {
        cancellation = nil
        readyReply = reply
        phase = .ready
    }

    func installing(applicationTerminated: Bool, retry: @escaping () -> Void) {
        readyReply = nil
        retryQuit = retry
        phase = .installing(waitingForQuit: !applicationTerminated)
    }

    func upToDate(_ caption: String, acknowledge: @escaping () -> Void) {
        clearReplies()
        release = nil; phase = .upToDate(caption)
        acknowledgement = acknowledge
    }

    func fail(_ message: String, acknowledge: @escaping () -> Void) {
        clearReplies()
        phase = .failed(message)
        acknowledgement = acknowledge
    }

    func reset() {
        clearReplies()
        phase = .idle; release = nil; userInitiated = false
    }

    private func clearReplies() {
        respond = nil; cancellation = nil; acknowledgement = nil; readyReply = nil; retryQuit = nil
    }

    // MARK: 用户操作

    func install() {
        if let release, release.informationOnly {
            // 只有说明的版本：打开官网页面，这次提醒算"稍后"。
            if let url = release.infoURL { NSWorkspace.shared.open(url) }
            reply(.later)
        } else {
            reply(.install)
        }
    }

    func later() { reply(.later) }
    func skip() { reply(.skip) }

    private func reply(_ choice: UpdateChoice) {
        guard let respond else { return }
        self.respond = nil
        respond(choice)
        // 选了安装：Sparkle 接着回调下载进度，窗口留着；其余选择结束本次提醒。
        if choice != .install { close() }
    }

    func cancel() {
        let cancellation = self.cancellation
        self.cancellation = nil
        cancellation?()
        close()
    }

    func restartNow() { finishReady(install: true) }
    func installOnQuit() { finishReady(install: false) }

    private func finishReady(install: Bool) {
        guard let readyReply else { return }
        self.readyReply = nil
        readyReply(install)
        if !install { close() }
    }

    func retryTermination() { retryQuit?() }

    func acknowledge() {
        let acknowledgement = self.acknowledgement
        self.acknowledgement = nil
        acknowledgement?()
        close()
    }

    func retry() {
        let retryCheck = self.retryCheck
        acknowledge()
        retryCheck?()
    }

    /// 红色关闭钮：按当前阶段换成对应的"温和"选择。下载、解包中关窗不取消，就绪后再把窗口带回来。
    /// 返回 false 表示只收起窗口、会话继续。
    func windowClosing() -> Bool {
        switch phase {
        case .checking: cancel()
        case .available: later()
        case .ready: installOnQuit()
        case .upToDate, .failed: acknowledge()
        case .downloading, .extracting, .installing: return false
        case .idle: break
        }
        return true
    }
}

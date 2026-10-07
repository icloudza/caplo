import SwiftUI
import AppKit
import CaploDesignSystem
import CaptureKit

/// 菜单栏和主菜单复用同一组窗口入口，暂停中的图片功能不再暴露给用户。
public struct CaploMenuView: View {
    public init() {}
    public var body: some View {
        if ScreenRecorder.shared.canStop {
            Button(ScreenRecorder.shared.phase == .paused ? "继续录制" : "暂停录制") {
                Task { if ScreenRecorder.shared.phase == .paused { await ScreenRecorder.shared.resume() } else { await ScreenRecorder.shared.pause() } }
            }
            Button("停止录制并保存") { Task { await ScreenRecorder.shared.stop() } }
            Divider()
        }
        Button(ScreenRecorder.shared.isBusy ? "显示录制控制" : "新建录制") { StudioWindows.showRecorder() }
        Button("项目中心") { ProjectLibraryWindow.shared.show() }.disabled(ScreenRecorder.shared.isBusy)
        Button("打开工程") { ProjectLibraryModel.shared.importProject() }.disabled(ScreenRecorder.shared.isBusy)
        Divider()
        Button("设置") { StudioWindows.showSettings() }
        UpdateMenuItem()
        Divider()
        Button("退出 Caplo") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}

public struct CaploAppCommands: Commands {
    public init() {}
    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建录制") { StudioWindows.showRecorder() }.shortcut(.newRecording)
            Button("打开工程") { ProjectLibraryModel.shared.importProject() }.shortcut(.openProject).disabled(ScreenRecorder.shared.isBusy)
            Button("项目中心") { ProjectLibraryWindow.shared.show() }.shortcut(.projectLibrary).disabled(ScreenRecorder.shared.isBusy)
        }
        CommandGroup(replacing: .appSettings) {
            Button("设置") { StudioWindows.showSettings() }.shortcut(.settings)
        }
        CommandGroup(after: .appInfo) { UpdateMenuItem() }
    }
}

/// "检查更新"：始终在菜单里；开发版没有更新配置时置灰。有新版本等着处理时改成"安装 Caplo x.y.z"。
struct UpdateMenuItem: View {
    private let updater = AppUpdater.shared
    var body: some View {
        if let version = updater.pendingVersion {
            Button("安装 Caplo \(version)") { updater.checkForUpdates() }
        } else {
            Button("检查更新") { updater.checkForUpdates() }.disabled(!updater.isEnabled || !updater.canCheck)
        }
    }
}

/// 菜单栏状态始终反映共享会话，录制窗口关闭后仍有明确的录制提示：录制中 C 中心的点变红并缓慢呼吸。
public struct RecordingMenuLabel: View {
    public init() {}
    public var body: some View {
        if ScreenRecorder.shared.isBusy {
            Image(nsImage: CaploBrand.menuBarRecordingImage(dotOpacity: MenuBarPulse.shared.opacity))
                .accessibilityLabel("Caplo · 录制中")
        } else {
            CaploBrand.menuBarIcon
                .resizable().scaledToFit().frame(width: 18, height: 18)
                .accessibilityLabel("Caplo")
        }
    }
}

/// 菜单栏红点的呼吸：只在正式录制时跑，约 2.4 秒一个来回，不透明度 0.4 ↔ 0.9（偏淡，不抢眼）。
/// 暂停时停在 0.4（看得出"还在录、但没在走"），倒计时、启动、收尾等过渡状态停在 0.75；减少动态效果时一律不动。
/// 菜单栏标签里的 SwiftUI 动画不会逐帧刷新，所以用 12 fps 的计时器改值，让标签重画。
@MainActor @Observable
final class MenuBarPulse {
    static let shared = MenuBarPulse()
    static let period = 2.4
    private(set) var opacity: CGFloat = 0.75
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var start = Date()

    func update(phase: ScreenRecorder.Phase) {
        let breathing = phase == .recording && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if breathing {
            guard timer == nil else { return }
            start = Date()
            let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { _ in MainActor.assumeIsolated { MenuBarPulse.shared.tick() } }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            tick()
        } else {
            timer?.invalidate(); timer = nil
            opacity = phase == .paused || phase == .pausing ? 0.4 : 0.75
        }
    }

    private func tick() {
        // 从最亮开始，余弦缓入缓出。
        let t = Date().timeIntervalSince(start) / Self.period
        opacity = 0.65 + 0.25 * cos(2 * .pi * t)
    }
}

/// 正常退出先完成文件收尾；启动中的退出暂缓，避免异步启动与销毁互相竞争。
public final class RecordingAppDelegate: NSObject, NSApplicationDelegate {
    private var openedFromFile = false
    public func applicationWillFinishLaunching(_ notification: Notification) {
        // 通知的代理要在启动完成前设好：应用被点"有新版本"通知拉起时，这次点击才不会丢。
        UpdateNotifier.shared.start()
    }
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 产品只有深色玻璃一套主题：系统弹窗、菜单与文件面板也统一按深色外观呈现。
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // 上次运行借走系统默认输入（语音处理单元只认默认输入）却没来得及还的话，先改回去，再起试听。
        MicrophoneDefaultInput.restoreIfLeftBehind()
        RecordingPresentation.shared.observe()
        CameraPreviewCoordinator.startObserving()
        // 隐藏 Dock 图标时以 .accessory 启动，编辑器 / 项目中心 / 设置开着时临时回到 Dock。
        AppPresence.start()
        // 在线更新：发布包才启动；后台检查不会在录制或导出时弹窗。
        AppUpdater.shared.start()
        // 登录时由系统拉起：只在菜单栏待命，不弹录制方式条。标记只在启动回调里读得到，先取出来。
        let quietLaunch = AppPresence.launchedAsLoginItem
        // 文件打开事件可能紧随启动到达；延后一轮，避免直接打开工程时闪现准备窗口。
        Task { @MainActor in
            await Task.yield()
            guard !quietLaunch, !openedFromFile, !VideoEditorWindow.shared.opening, !VideoEditorWindow.shared.isVisible else { return }
            // 屏幕录制还没授权：先出权限窗口，关掉后再出录制方式条（不再让系统询问框和"无法读取来源"的报错直接冒出来）。
            PermissionCenter.shared.refresh()
            // 引导没走完（包括系统为屏幕录制授权重启应用之后）也继续显示，让用户接着授权麦克风、摄像头。
            if PermissionsWindow.enforced, !PermissionCenter.shared.screenGranted || !PermissionCenter.onboardingDone { PermissionsWindow.shared.show(.launch) }
            else { StudioWindows.showRecorder() }
        }
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension == "caplo" }) else { return }
        openedFromFile = true
        VideoEditorWindow.shared.show(project: url)
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        StudioWindows.reopen()
        return false
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 正在导出：先问。以前直接退出，导出白做，目标文件夹里还留下隐藏的临时文件。
        if let editor = VideoEditorSessions.current, editor.exporting {
            let alert = NSAlert()
            alert.messageText = String(localized: "正在导出视频")
            alert.informativeText = String(localized: "现在退出会取消这次导出。")
            alert.addButton(withTitle: String(localized: "继续导出"))
            alert.addButton(withTitle: String(localized: "取消导出并退出"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            Task { @MainActor in
                // 等导出收尾（删掉临时文件）后再走一遍正常的退出检查。
                await editor.cancelExportAndWait()
                let reply = self.applicationShouldTerminate(sender)
                if reply != .terminateLater { sender.reply(toApplicationShouldTerminate: reply == .terminateNow) }
            }
            return .terminateLater
        }
        guard VideoEditorSessions.closeCurrent(close: false) else { return .terminateCancel }
        let recorder = ScreenRecorder.shared
        if recorder.phase == .countdown { StudioWindows.terminating = true; recorder.cancelCountdown(); return .terminateNow }
        if recorder.isBusy && !recorder.canStop {
            let alert = NSAlert()
            alert.messageText = String(localized: "录制正在启动或保存")
            alert.informativeText = String(localized: "请稍后再退出，以便完成当前操作。")
            alert.runModal()
            return .terminateCancel
        }
        guard recorder.canStop else { StudioWindows.terminating = true; return .terminateNow }
        StudioWindows.terminating = true
        Task { @MainActor in
            await recorder.stop()
            if let error = recorder.errorMessage {
                let alert = NSAlert()
                alert.messageText = String(localized: "请先检查录制保存结果")
                alert.informativeText = error
                alert.runModal()
                StudioWindows.terminating = false
                StudioWindows.showRecorder()
                sender.reply(toApplicationShouldTerminate: false)
            } else {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

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
        Button("打开工程…") { ProjectLibraryModel.shared.importProject() }.disabled(ScreenRecorder.shared.isBusy)
        Divider()
        Button("设置…") { StudioWindows.showSettings() }
        Divider()
        Button("退出 Caplo") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}

public struct CaploAppCommands: Commands {
    public init() {}
    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建录制") { StudioWindows.showRecorder() }.keyboardShortcut("n")
            Button("打开工程…") { ProjectLibraryModel.shared.importProject() }.keyboardShortcut("o").disabled(ScreenRecorder.shared.isBusy)
            Button("项目中心") { ProjectLibraryWindow.shared.show() }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(ScreenRecorder.shared.isBusy)
        }
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { StudioWindows.showSettings() }.keyboardShortcut(",")
        }
    }
}

/// 菜单栏状态始终反映共享会话，录制窗口关闭后仍有明确的录制提示。
public struct RecordingMenuLabel: View {
    public init() {}
    public var body: some View {
        let recording = ScreenRecorder.shared.isBusy
        (recording ? CaploBrand.menuBarRecordingIcon : CaploBrand.menuBarIcon)
            .resizable().scaledToFit().frame(width: 18, height: 18)
            .accessibilityLabel(recording ? "Caplo · 录制中" : "Caplo")
    }
}

/// 正常退出先完成文件收尾；启动中的退出暂缓，避免异步启动与销毁互相竞争。
public final class RecordingAppDelegate: NSObject, NSApplicationDelegate {
    private var openedFromFile = false
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 产品只有深色玻璃一套主题：系统弹窗、菜单与文件面板也统一按深色外观呈现。
        NSApp.appearance = NSAppearance(named: .darkAqua)
        RecordingPresentation.shared.observe()
        NSApp.setActivationPolicy(.regular)
        // 文件打开事件可能紧随启动到达；延后一轮，避免直接打开工程时闪现准备窗口。
        Task { @MainActor in
            await Task.yield()
            if !openedFromFile, !VideoEditorWindow.shared.opening, !VideoEditorWindow.shared.isVisible { StudioWindows.showRecorder() }
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
        guard VideoEditorSessions.closeCurrent(close: false) else { return .terminateCancel }
        let recorder = ScreenRecorder.shared
        if recorder.phase == .countdown { StudioWindows.terminating = true; recorder.cancelCountdown(); return .terminateNow }
        if recorder.isBusy && !recorder.canStop {
            let alert = NSAlert()
            alert.messageText = "录制正在启动或保存"
            alert.informativeText = "请稍后再退出，以便完成当前操作。"
            alert.runModal()
            return .terminateCancel
        }
        guard recorder.canStop else { StudioWindows.terminating = true; return .terminateNow }
        StudioWindows.terminating = true
        Task { @MainActor in
            await recorder.stop()
            if let error = recorder.errorMessage {
                let alert = NSAlert()
                alert.messageText = "请先检查录制保存结果"
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

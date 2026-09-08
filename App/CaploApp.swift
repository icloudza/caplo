import SwiftUI
import Features

@main
struct CaploApp: App {
    @NSApplicationDelegateAdaptor(RecordingAppDelegate.self) private var appDelegate
    var body: some Scene {
        // 业务窗口由 AppKit 协调器管理，避免 SwiftUI 自动恢复旧项目首页。
        // 不声明 Settings 场景：没有主 Window 场景时 SwiftUI 会在启动时自动打开它，
        // 设置窗口由 StudioWindows.showSettings 提供，⌘, 在 CaploAppCommands 中定义。
        MenuBarExtra { CaploMenuView() } label: { RecordingMenuLabel() }
            .commands { CaploAppCommands() }
    }
}

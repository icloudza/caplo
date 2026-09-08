import AppKit
import AVFoundation
import CaptureKit
import Foundation
import SwiftUI
import CaploDesignSystem

/// 窗口回归：实际创建每个窗口并让 AppKit 跑完显示周期，任何未捕获异常即失败。
/// 由 `PreviewGallery --windows` 调用，纳入 `Scripts/check.sh`。
@MainActor
public enum WindowSmokeTest {
    /// 单独打开组件画廊（真实窗口、深色），停到窗口关闭为止；供人工评审设计系统控件。
    public static func showGallery() {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "组件画廊"
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: DesignSystemGallery().preferredColorScheme(.dark))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        while window.isVisible { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2)) }
    }

    public static func run(projectURL: URL?) throws {
        NSSetUncaughtExceptionHandler { exception in
            FileHandle.standardError.write(Data("窗口回归失败：\(exception.name.rawValue) \(exception.reason ?? "")\n".utf8))
            exit(3)
        }
        NSApp.setActivationPolicy(.accessory)

        var steps: [(String, () -> Void)] = [
            ("录制准备", { StudioWindows.showRecorder() }),
            ("设置", { StudioWindows.showSettings() }),
            ("项目中心", { ProjectLibraryWindow.shared.show() }),
            ("录制条", { StudioWindows.showRecordBar(.preview()) }),
            ("摄像头画中画", { CameraPreviewSession.show(feed: CameraFeed(queue: DispatchQueue(label: "smoke.camera")), on: NSScreen.main ?? NSScreen.screens[0]) }),
            ("录制条（窗口）", { StudioWindows.showRecordBar(.preview(mode: "窗口", sourceTitle: "预览 — 窗口")) }),
            // 设计系统的全部控件在真实窗口里走一遍显示周期（离屏位图看不出菜单、材质与焦点环的真实表现）。
            ("组件画廊", {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "组件画廊"
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = NSHostingView(rootView: DesignSystemGallery().preferredColorScheme(.dark))
                window.center()
                window.orderFrontRegardless()
            }),
        ]
        if let projectURL {
            steps.append(("编辑器", { VideoEditorWindow.shared.show(project: projectURL) }))
        }
        for (name, step) in steps {
            step()
            // 两轮显示周期：第一轮布局与约束，第二轮验证不再反复请求约束更新。
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
            print("窗口正常：\(name)")
        }
        // 调试辅助：CAPLO_SMOKE_HOLD=秒数 时让所有窗口停留指定时间，便于在真实屏幕上截图核对渲染；
        // 同时在最底下铺一层与区域遮罩相近的灰底，浮动条边缘的问题在平色上最容易看出来。
        if let hold = ProcessInfo.processInfo.environment["CAPLO_SMOKE_HOLD"].flatMap(Double.init), hold > 0 {
            let backdrop = NSWindow(contentRect: NSScreen.main?.frame ?? .zero, styleMask: .borderless, backing: .buffered, defer: false)
            backdrop.backgroundColor = NSColor(calibratedWhite: 0.68, alpha: 1)
            backdrop.hasShadow = false
            backdrop.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
            backdrop.orderFrontRegardless()
            // 编辑器异步载入后可能被后显示的窗口盖住；停留期间把最大的窗口（编辑器）放到最前。
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.5))
            NSApp.windows.filter { $0.isVisible && $0 !== backdrop }.max { $0.frame.width < $1.frame.width }?.orderFrontRegardless()
            for window in NSApp.windows where window !== backdrop {
                FileHandle.standardError.write(Data("停留窗口：\(window.title) 可见=\(window.isVisible) 尺寸=\(Int(window.frame.width))×\(Int(window.frame.height)) 层级=\(window.level.rawValue)\n".utf8))
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: hold))
            backdrop.orderOut(nil)
        }
        for window in NSApp.windows { window.orderOut(nil) }
    }
}

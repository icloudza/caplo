import AppKit
import SwiftUI
import CaptureKit
import Testing
import ProjectKit
@testable import Features

/// 在自身测试进程创建真实 NSWindow，只使用临时空工程；不采集桌面或扫描用户项目库。
/// 验证重复打开、会话保存失败及关闭重开，不能替代鼠标、Dock 和系统权限交互验收。
@Suite(.serialized) @MainActor
struct WindowLifecycleTests {

    @Test func recorderAndEditorPreserveWindowAndSessionLifetimes() async throws {
        _ = NSApplication.shared
        StudioWindows.terminating = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = try ProjectStorage.create(in: root, name: "窗口生命周期测试").resolvingSymlinksInPath()
        try ProjectStorage.complete(url)
        let previousExternal = UserDefaults.standard.object(forKey: "externalProjects")
        defer {
            StudioWindows.terminating = true
            for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("caplo-") == true { window.close() }
            UserDefaults.standard.set(previousExternal, forKey: "externalProjects")
            try? FileManager.default.removeItem(at: root)
        }
        let delegate = RecordingAppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try await waitFor { windows("caplo-recorder").first?.isVisible == true }
        let recorder = try #require(windows("caplo-recorder").first)
        StudioWindows.showRecorder()
        #expect(windows("caplo-recorder").count == 1)
        #expect(!recorder.styleMask.contains(.resizable))
        let content = try #require(recorder.contentView)
        #expect(abs(content.frame.width - ModePickerView.size.width) < 1)
        #expect(abs(content.frame.height - ModePickerView.size.height) < 1)

        // 等待多轮布局后验证生产窗口的透明宿主与唯一采样层；使用语义标识而非泛型类型名。
        try await Task.sleep(for: .milliseconds(250))
        let host = try await assertTransparentGlassHost(in: recorder, floating: true)
        #expect(abs(host.bounds.height - content.frame.height) < 1)
        let oldAppearance = recorder.appearance
        recorder.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        // cacheDisplay 不含 WindowServer 的真实桌面合成，允许玻璃留下透明像素。
        // 仍检查底边多个位置没有孤立实白条；用预乘颜色比较，避免透明像素的隐藏 RGB 干扰结果。
        for fraction in [0.2, 0.5, 0.8] {
            let x = Int(Double(bitmap.pixelsWide - 1) * fraction)
            let bottom = try #require(bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 5)?.usingColorSpace(.deviceRGB))
            let adjacent = try #require(bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 8)?.usingColorSpace(.deviceRGB))
            #expect(!(bottom.alphaComponent > 0.9 && bottom.redComponent > 0.92 && bottom.greenComponent > 0.92 && bottom.blueComponent > 0.92))
            #expect(abs(bottom.alphaComponent - adjacent.alphaComponent) < 0.035)
            #expect(abs(bottom.redComponent * bottom.alphaComponent - adjacent.redComponent * adjacent.alphaComponent) < 0.025)
            #expect(abs(bottom.greenComponent * bottom.alphaComponent - adjacent.greenComponent * adjacent.alphaComponent) < 0.025)
            #expect(abs(bottom.blueComponent * bottom.alphaComponent - adjacent.blueComponent * adjacent.alphaComponent) < 0.025)
        }
        try writeArtifact(recorder, name: "recorder-window")
        recorder.appearance = oldAppearance

        let management = StudioWindows.make(title: "隔离项目中心", content: ProjectLibraryView(previewOnly: true), size: CGSize(width: 900, height: 620))
        ProjectLibraryWindow.configureManagementWindow(management)
        management.orderFront(nil)
        _ = try await assertTransparentGlassHost(in: management)
        #expect(!management.styleMask.contains(.miniaturizable))
        #expect(management.collectionBehavior.contains(.fullScreenNone))
        #expect(management.standardWindowButton(.miniaturizeButton)?.isHidden != false)
        #expect(management.standardWindowButton(.zoomButton)?.isHidden != false)
        #expect(management.standardWindowButton(.closeButton)?.isHidden == false)
        try writeArtifact(management, name: "project-center-window")
        management.close()

        delegate.application(NSApp, open: [url])
        try await waitFor { VideoEditorSessions.current?.ready == true }
        let original = try #require(VideoEditorSessions.current)
        let editor = try #require(windows("caplo-video-editor").first)
        _ = try await assertTransparentGlassHost(in: editor)
        #expect(editor.isVisible)
        #expect(!recorder.isVisible)
        original.commit { $0.layout.padding = 42 }
        VideoEditorWindow.shared.show(project: url)
        #expect(VideoEditorSessions.current === original)
        #expect(windows("caplo-video-editor").count == 1)

        // 使编辑目标临时变成目录，真实触发写入失败，检查内存编辑与排他租约仍保留。
        // 存盘在后台进行：先等上一笔落盘，否则挪走文件时它可能正被原子改名写回来。
        original.settlePendingSaves()
        let edits = url.appendingPathComponent("edits.json")
        let backup = url.appendingPathComponent("edits-backup.json")
        try FileManager.default.moveItem(at: edits, to: backup)
        try FileManager.default.createDirectory(at: edits, withIntermediateDirectories: false)
        original.commit { $0.layout.padding = 49 }
        // 写盘在后台进行：结果回到主线程后才显示"保存失败"；关窗时 flush 会同步等它。
        try await waitFor { original.saveStatus == "保存失败" }
        #expect(!original.close())
        #expect(VideoEditorSessions.current === original)
        #expect(throws: (any Error).self) { try ProjectLease(url: url) }
        try FileManager.default.removeItem(at: edits)
        try FileManager.default.moveItem(at: backup, to: edits)
        original.retrySave()
        #expect(original.saveStatus == "已保存")

        editor.performClose(nil)
        try await waitFor { VideoEditorSessions.current == nil && recorder.isVisible }
        VideoEditorWindow.shared.show(project: url)
        try await waitFor { VideoEditorSessions.current?.ready == true }
        #expect(VideoEditorSessions.current !== original)
        #expect(VideoEditorSessions.current?.edit.layout.padding == 49)
        #expect(windows("caplo-video-editor").count == 1)
        _ = try await assertTransparentGlassHost(in: editor)
        editor.performClose(nil)
        try await waitFor { recorder.isVisible }
    }

    /// 生产入口允许底图穿过窗口与宿主，由唯一 behindWindow 材质层采样；不把配置断言当作桌面像素证据。
    /// `floating`：贴底浮动条采用 HUD 材质（`CaploMaterialKind.floating`），主窗口采用窗口材质。
    private func assertTransparentGlassHost(in window: NSWindow, floating: Bool = false) async throws -> NSView {
        #expect(!window.isOpaque)
        #expect(window.backgroundColor.alphaComponent < 0.001)
        let container = try #require(window.contentView)
        #expect(container.identifier?.rawValue == "caplo.window.content-container")
        #expect(!container.isOpaque)
        #expect(container.subviews.count == 1)
        let host = try #require(container.subviews.first)
        #expect(host.identifier?.rawValue == "caplo.window.content-host")
        #expect(!host.isOpaque)
        for layer in [container.layer, host.layer].compactMap({ $0 }) {
            #expect(!layer.isOpaque)
            #expect((layer.backgroundColor?.alpha ?? 0) < 0.001)
        }
        host.layoutSubtreeIfNeeded()
        let reducesTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let expectedCount = reducesTransparency ? 0 : 1
        try await waitFor { materialBackdrops(in: host).count == expectedCount }
        let backdrops = materialBackdrops(in: host)
        #expect(backdrops.count == expectedCount)
        for backdrop in backdrops {
            #expect(backdrop.blendingMode == .behindWindow)
            #expect(backdrop.material == (floating ? .hudWindow : .underWindowBackground))
            #expect(backdrop.state == .active)
            // 只由上层中性遮罩控制透光；削弱整个采样层会混入未模糊的背景文字。
            #expect(backdrop.alphaValue == 1)
            #expect(backdrop.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        }
        return host
    }

    private func materialBackdrops(in view: NSView) -> [NSVisualEffectView] {
        var result: [NSVisualEffectView] = []
        if let effect = view as? NSVisualEffectView, effect.identifier?.rawValue == "caplo.material.backdrop" { result.append(effect) }
        for child in view.subviews { result += materialBackdrops(in: child) }
        return result
    }

    /// 仅导出本测试进程创建的窗口视图，不使用桌面截取或辅助功能权限。
    private func writeArtifact(_ window: NSWindow, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["CAPLO_UI_ARTIFACTS_DIR"],
              let frame = window.contentView?.superview else { return }
        frame.layoutSubtreeIfNeeded()
        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"), options: .atomic)
    }

    private func windows(_ identifier: String) -> [NSWindow] {
        NSApp.windows.filter { $0.identifier?.rawValue == identifier }
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WindowCheckError.timeout
    }
    private enum WindowCheckError: Error { case timeout }
}


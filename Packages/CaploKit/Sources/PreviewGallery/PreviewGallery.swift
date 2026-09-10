import AppKit
import SwiftUI
import Features
import CaptureKit
import CaploDesignSystem
import ProjectKit
import EditingCore

/// 离屏检查 SwiftUI 布局，生成的图片不是真实应用窗口截图。
/// AppKit 材质、控件交互和窗口合成效果仍需单独进行原生界面验收。
@main
struct PreviewGallery {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/caplo-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--material-review") {
            let url = try await PreviewFixture.create(camera: true, pointer: true)
            try await MaterialReview.render(projectURL: url, output: output)
            return
        }
        if CommandLine.arguments.contains("--timeline-interaction-review") || CommandLine.arguments.contains("--timeline-shared-review") {
            let url = try await PreviewFixture.create(camera: false, pointer: true)
            try await TimelineInteractionReview.render(projectURL: url, output: output, sharedRows: CommandLine.arguments.contains("--timeline-shared-review"))
            return
        }
        if CommandLine.arguments.contains("--timeline-review") {
            let key = "editor.timelineHeight", previous = UserDefaults.standard.object(forKey: "editor.timelineHeight")
            UserDefaults.standard.set(570.0, forKey: key)
            defer { UserDefaults.standard.set(previous, forKey: key) }
            let url = try await PreviewFixture.create(camera: true, pointer: true)
            let document = try ProjectStorage.load(url)
            var edit = try EditStorage.load(in: url, document: document)
            edit.prepareLayerEditing(camera: true, system: false, microphone: true)
            edit.focuses = []
            for clip in edit.clips {
                var focus = FocusSegment(start: clip.sourceStart, duration: min(2, clip.duration), x: 0.5, y: 0.5)
                focus.timelineStart = (clip.timelineStart ?? 0) + 0.5; focus.targetClipID = clip.id
                edit.focuses.append(focus); edit.moveLayer(focus.id, before: clip.id)
            }
            try EditStorage.save(edit, in: url, document: document)
            for scheme in [ColorScheme.light, .dark] {
                try await render(VideoEditorPreview(projectURL: url, time: 5, initialTab: "聚焦"), name: "timeline-layers-" + (scheme == .light ? "light" : "dark"), size: CGSize(width: 1360, height: 960), scheme: scheme, output: output)
            }
            return
        }
        if CommandLine.arguments.contains("--cursor-review") {
            let url = try await PreviewFixture.create(camera: false, pointer: true)
            for scheme in [ColorScheme.light, .dark] {
                let name = scheme == .dark ? "dark" : "light"
                try await render(VideoEditorPreview(projectURL: url, time: 2.4, initialTab: "光标"), name: "cursor-latest-" + name, size: CGSize(width: 1360, height: 860), scheme: scheme, output: output)
                try await render(VideoEditorPreview(projectURL: url, time: 2.4, initialTab: "聚焦"), name: "focus-latest-" + name, size: CGSize(width: 1360, height: 860), scheme: scheme, output: output)
            }
            var document = try ProjectStorage.load(url); document.capture?.cursorEmbedded = true
            try ProjectStorage.save(document, to: url)
            try await render(VideoEditorPreview(projectURL: url, time: 2.4, initialTab: "光标"), name: "cursor-embedded", size: CGSize(width: 1360, height: 860), scheme: .light, output: output)
            return
        }
        if CommandLine.arguments.contains("--performance") {
            try await EditorBenchmark.run(output: output)
            return
        }
        if CommandLine.arguments.contains("--components") {
            try await render(DesignSystemGallery(), name: "components-light", size: CGSize(width: 1100, height: 760), scheme: .light, output: output)
            try await render(DesignSystemGallery(), name: "components-dark", size: CGSize(width: 1100, height: 760), scheme: .dark, output: output)
            // 分段选择单独出一张：画廊整页离屏位图里面板材质不出，看不清它。
            try await render(SegmentedBarSample(), name: "segmented-bar", size: CGSize(width: 300, height: 120), scheme: .dark, output: output)
            return
        }
        if CommandLine.arguments.contains("--onboarding") {
            // 打开方式条并强制播放首次使用引导，直到引导结束或方式条收起；供真实屏幕核对。
            WindowSmokeTest.showOnboarding()
            return
        }
        if CommandLine.arguments.contains("--gallery") {
            // 只开组件画廊一个真实窗口给人看，关掉窗口即退出。
            WindowSmokeTest.showGallery()
            return
        }
        if CommandLine.arguments.contains("--windows") {
            let fixture = try await PreviewFixture.create(camera: false, pointer: false)
            try WindowSmokeTest.run(projectURL: fixture)
            return
        }
        try await render(ProjectLibraryView(previewOnly: true), name: "project-center-empty", size: CGSize(width: 900, height: 620), scheme: .light, output: output)
        // 浮动条预览垫在画布底色上，否则浅色条在白底上看不出边缘与阴影。
        try await render(ModePickerView().background(CaploColor.surfaceCanvasWell), name: "mode-picker", size: ModePickerView.size, scheme: .light, output: output)
        try await render(ModePickerView().background(CaploColor.surfaceCanvasWell), name: "mode-picker-dark", size: ModePickerView.size, scheme: .dark, output: output)
        try await render(RecordBarView(model: .preview()).background(CaploColor.surfaceCanvasWell), name: "record-bar", size: RecordBarView.panelSize, scheme: .light, output: output)
        try await render(RecordBarView(model: .preview()).background(CaploColor.surfaceCanvasWell), name: "record-bar-dark", size: RecordBarView.panelSize, scheme: .dark, output: output)
        // 麦克风试听中：跳动图标替换话筒图标，核对与标题的对齐。
        UserDefaults.standard.set(true, forKey: "recording.microphone")
        MicrophoneMonitor.shared.simulate(level: 0.8)
        try await render(RecordBarView(model: .preview()).background(CaploColor.surfaceCanvasWell), name: "record-bar-monitoring", size: RecordBarView.panelSize, scheme: .dark, output: output)
        MicrophoneMonitor.shared.stop()
        UserDefaults.standard.removeObject(forKey: "recording.microphone")
        try await render(RecordingControls(state: .countdown(3)).background(CaploColor.surfaceCanvasWell), name: "record-countdown", size: RecordingControls.panelSize, scheme: .dark, output: output)
        try await render(RecordingControls(state: .recording(elapsed: 12.4, paused: false, stopping: false, canStop: true)).background(CaploColor.surfaceCanvasWell), name: "record-controls", size: RecordingControls.panelSize, scheme: .dark, output: output)
        try await render(RecordingControls(state: .recording(elapsed: 12.4, paused: false, stopping: false, canStop: true)).background(CaploColor.surfaceCanvasWell), name: "record-controls-light", size: RecordingControls.panelSize, scheme: .light, output: output)
        try await render(StudioConfirmSheet(title: "删除 3 个工程？", message: "“录制 2026年9月7日 4:30”、“录制 2026年9月7日 3:34”、“录制 2026年9月7日 3:25”会移到废纸篓，可从访达恢复。", confirmTitle: "删除 3 项", danger: true, confirm: {}, cancel: {}).background(CaploColor.surfaceCanvasWell), name: "confirm-sheet", size: CGSize(width: 380, height: 190), scheme: .dark, output: output)
        try await render(CaploSettingsView(), name: "settings", size: CaploSettingsView.size, scheme: .light, output: output)
        try await render(CaploSettingsView(), name: "settings-dark", size: CaploSettingsView.size, scheme: .dark, output: output)
        if let argument = CommandLine.arguments.dropFirst(2).first {
            let path: String
            if ["--demo", "--camera-demo", "--pointer-demo"].contains(argument) { path = try await PreviewFixture.create(camera: argument != "--demo", pointer: argument == "--pointer-demo").path; print("合成工程：" + path) }
            else { path = argument }
            try await render(ProjectLibraryView(previewOnly: true, previewProjectURL: URL(fileURLWithPath: path)), name: "project-center", size: CGSize(width: 900, height: 620), scheme: .light, output: output)
            try await render(ProjectLibraryView(previewOnly: true, previewProjectURL: URL(fileURLWithPath: path)), name: "project-center-dark", size: CGSize(width: 900, height: 620), scheme: .dark, output: output)
            try await render(ProjectLibraryView(previewOnly: true, previewProjectURL: URL(fileURLWithPath: path), previewError: "工程正在编辑，请先关闭编辑器。"), name: "project-center-error", size: CGSize(width: 900, height: 620), scheme: .dark, output: output)
            try await render(VideoEditorPreview(projectURL: URL(fileURLWithPath: path)), name: "editor-light", size: CGSize(width: 1360, height: 860), scheme: .light, output: output)
            try await render(VideoEditorPreview(projectURL: URL(fileURLWithPath: path)), name: "editor-dark", size: CGSize(width: 1360, height: 860), scheme: .dark, output: output)
            try await render(VideoEditorPreview(projectURL: URL(fileURLWithPath: path), time: 2.5), name: "editor-focus", size: CGSize(width: 1360, height: 860), scheme: .dark, output: output)
            try await render(VideoEditorPreview(projectURL: URL(fileURLWithPath: path), initialTab: "音频"), name: "editor-audio", size: CGSize(width: 1360, height: 860), scheme: .light, output: output)
            try await render(VideoEditorPreview(projectURL: URL(fileURLWithPath: path), initialTab: "音频"), name: "editor-audio-dark", size: CGSize(width: 1360, height: 860), scheme: .dark, output: output)
            if argument == "--camera-demo" || argument == "--pointer-demo" {
                try await render(VideoEditorPreview(projectURL: URL(fileURLWithPath: path), initialTab: "人像"), name: "editor-camera", size: CGSize(width: 1360, height: 860), scheme: .light, output: output)
                try await render(VideoEditorPreview(projectURL: URL(fileURLWithPath: path), initialTab: "人像"), name: "editor-camera-dark", size: CGSize(width: 1360, height: 860), scheme: .dark, output: output)
            }
            // 排版与外观默认收起，展开它们快照里才有色板与字体这一串参数。
            UserDefaults.standard.set(true, forKey: "editor.text.typographyExpanded")
            UserDefaults.standard.set(true, forKey: "editor.text.appearanceExpanded")
            try await render(VideoEditorPreview(projectURL: URL(fileURLWithPath: path), time: 2.5, initialTab: "文字"), name: "editor-text", size: CGSize(width: 1360, height: 860), scheme: .dark, output: output)
            try await render(VideoEditorPreview(projectURL: URL(fileURLWithPath: path), initialTab: "裁剪"), name: "editor-crop", size: CGSize(width: 1360, height: 860), scheme: .dark, output: output)
            try await render(VideoEditorPreview(projectURL: URL(fileURLWithPath: path), initialTab: "片段"), name: "editor-clip", size: CGSize(width: 1360, height: 860), scheme: .dark, output: output)
            if argument == "--pointer-demo" {
                try await render(VideoEditorPreview(projectURL: URL(fileURLWithPath: path), time: 2.4, initialTab: "光标"), name: "editor-pointer", size: CGSize(width: 1360, height: 860), scheme: .light, output: output)
                try await render(VideoEditorPreview(projectURL: URL(fileURLWithPath: path), time: 2.4, initialTab: "光标"), name: "editor-pointer-dark", size: CGSize(width: 1360, height: 860), scheme: .dark, output: output)
            }
        }
    }

    @MainActor
    private static func render<V: View>(_ view: V, name: String, size: CGSize, scheme: ColorScheme, output: URL) async throws {
        // 使用 NSHostingView 绘制，避免 ImageRenderer 遗漏 AppKit 控件与滚动容器。
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.orderOut(nil) }
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // 给原生控件一次布局机会；短暂等待仅用于离屏工具，不代表真实界面已稳定。
        try await Task.sleep(for: .seconds(2))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw PreviewError.renderFailed(name) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw PreviewError.renderFailed(name) }
        let url = output.appendingPathComponent("\(name).png")
        try data.write(to: url, options: .atomic)
        print(url.path)
    }

    enum PreviewError: Error {
        case renderFailed(String)
    }
}


/// 深色底上的分段选择样例：默认选中第三项，供离屏核对外观。
private struct SegmentedBarSample: View {
    @State private var selection = "左分屏"
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("版式").font(CaploFont.body).foregroundStyle(CaploColor.textPrimary)
            SegmentedBar(["叠加", "全屏", "左分屏", "右分屏"], selection: $selection) { $0 }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CaploColor.surfaceOpaquePanel)
    }
}

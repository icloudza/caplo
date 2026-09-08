import AppKit
import SwiftUI
import QuartzCore
import ProjectKit
import ExportKit
import CaploDesignSystem

/// 材质审核只显示本进程窗口和合成录屏工程；不录屏、不读取其他应用或更改系统辅助功能设置。
/// 审核把生产材质改用 withinWindow 采样自身环境；cacheDisplay 仍不能代替生产 behindWindow 的系统合成验收。
@MainActor
public enum MaterialReview {
    public static func render(projectURL: URL, output: URL) async throws {
        NSApp.setActivationPolicy(.accessory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "Caplo.MaterialReview.\(UUID().uuidString)")!
        // 只注册隔离默认值，不改变用户的外观、设备和编辑器偏好。
        defaults.register(defaults: ["appearance": "system", "recording.microphone": true,
                                     "recording.systemAudio": true, "recording.camera": false,
                                     "editor.timelineHeight": 290.0])
        let probeOnly = ProcessInfo.processInfo.environment["CAPLO_MATERIAL_REVIEW_PROBE"] == "1"
        var records: [OutputRecord] = []
        let probeModes: [Mode] = probeOnly ? [.standard] : [.standard, .reducedTransparency, .highContrast]
        let appearances = probeOnly ? [false] : [false, true]
        let backgrounds: [Background] = probeOnly ? [.dusk, .meadow] : Background.allCases
        for mode in probeModes {
            for dark in appearances {
                for background in backgrounds {
                    records.append(try await renderWindow(
                        Color.clear.background(CaploMaterialBackground(.window)),
                        size: CGSize(width: 240, height: 160), margin: CGSize(width: 32, height: 32), name: "probe",
                        configuration: Configuration(dark: dark, mode: mode, background: background),
                        defaults: defaults, output: output, probe: true))
                }
            }
        }
        let evidence = probeEvidence(records)
        var canvasSize = CGSize.zero
        if !probeOnly {
            let document = try ProjectStorage.load(projectURL)
            let model = VideoEditorModel(entry: LibraryEntry(url: projectURL, document: document))
            model.canvas.snapshotMode = true
            await model.open()
            defer { model.close() }
            for _ in 0..<500 {
                if model.ready && !model.loading && !model.rebuilding { break }
                if let error = model.error { throw ReviewError.failed(error) }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard model.ready, !model.loading, !model.rebuilding else { throw ReviewError.failed("合成编辑器未能就绪") }
            model.seek(5)
            let renderer = EditorPreviewRenderer()
            let frame: CGImage
            do { frame = try await renderer.render(url: projectURL, document: document, edit: model.edit, time: 5) }
            catch { await renderer.close(); throw error }
            await renderer.close()
            model.canvas.present(image: frame)
            canvasSize = CGSize(width: frame.width, height: frame.height)
            for mode in [Mode.standard, .reducedTransparency, .highContrast] {
                for dark in [false, true] {
                    // 普通模式完整比较三种环境；不透明回退只需完整窗口夜幕图，三背景已由上方探针覆盖。
                    let sceneBackgrounds: [Background] = mode == .standard ? Background.allCases : [.night]
                    for background in sceneBackgrounds {
                        let configuration = Configuration(dark: dark, mode: mode, background: background)
                        records.append(try await renderWindow(
                            RecordBarView(model: .preview()), size: RecordBarView.panelSize,
                            margin: CGSize(width: 70, height: 66), name: "record-bar", configuration: configuration,
                            defaults: defaults, output: output))
                        records.append(try await renderWindow(
                            VideoEditorView(model: model, initialTab: "光标", back: {}),
                            size: CGSize(width: 1360, height: 860), margin: CGSize(width: 32, height: 32),
                            name: "editor", configuration: configuration, defaults: defaults, output: output,
                            prepareFrame: { model.canvas.present(image: frame) }))
                        records.append(try await renderWindow(
                            CaploSettingsView(), size: CaploSettingsView.size, margin: CGSize(width: 48, height: 48),
                            name: "settings", configuration: configuration, defaults: defaults, output: output))
                        records.append(try await renderWindow(
                            ProjectLibraryView(previewOnly: true, previewProjectURL: projectURL),
                            size: CGSize(width: 900, height: 620), margin: CGSize(width: 32, height: 32),
                            name: "project-center", configuration: configuration, defaults: defaults, output: output))
                        records.append(try await renderWindow(
                            ModePickerView(), size: ModePickerView.size, margin: CGSize(width: 48, height: 48),
                            name: "mode-picker", configuration: configuration, defaults: defaults, output: output))
                    }
                }
            }
        }
        let report = Report(
            description: "自有窗口中性玻璃审核：暖霞、林间、夜幕完全由程序绘制；真实业务视图复用生产材质。",
            limitation: "本工具仅把背景采样改为 withinWindow，以便采样同进程绘制环境。PNG 来自 NSView.cacheDisplay；探针单独报告位图是否包含背景及边缘柔化。它与生产 behindWindow 的 WindowServer 合成不同，不证明真实桌面透光或跨系统性能。",
            source: projectURL.path, canvasWidth: Int(canvasSize.width), canvasHeight: Int(canvasSize.height),
            probeOnly: probeOnly, probeEvidence: evidence, outputs: records)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = output.appendingPathComponent("material-review.json")
        try encoder.encode(report).write(to: manifest, options: .atomic)
        print(manifest.path)
        for item in evidence { print("材质探针：\(item.mode) / \(item.appearance)，背景差=\(item.maximumBackgroundDifference)，位图柔化=\(item.bitmapIncludesEdgeSoftening)") }
    }

    private static func renderWindow<V: View>(
        _ content: V, size: CGSize, margin: CGSize, name: String, configuration: Configuration,
        defaults: UserDefaults, output: URL, probe: Bool = false, prepareFrame: (() -> Void)? = nil
    ) async throws -> OutputRecord {
        let stageSize = CGSize(width: size.width + margin.width * 2, height: size.height + margin.height * 2)
        let bounds = CGRect(origin: .zero, size: stageSize)
        let host = NSHostingView(rootView: content
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, configuration.dark ? .dark : .light)
            .caploMaterialBackdropPreview(withinWindow: true)
            .caploMaterialAccessibilityPreview(reduceTransparency: configuration.mode == .reducedTransparency,
                                               highContrast: configuration.mode == .highContrast)
            .defaultAppStorage(defaults))
        host.frame = CGRect(origin: CGPoint(x: margin.width, y: margin.height), size: size)
        host.sizingOptions = []

        // 与生产窗口的唯一材质策略差异是 withinWindow：只采样同一个 NSView 树中的自绘背景。
        let stage = EnvironmentView(frame: bounds, background: configuration.background, probe: probe)
        stage.wantsLayer = true
        stage.addSubview(host)
        let window = makeWindow(size: stageSize, appearance: configuration.appearance)
        window.contentView = stage
        window.center(); window.orderFront(nil)
        var closed = false
        func closeWindow() {
            guard !closed else { return }
            closed = true
            window.orderOut(nil); window.contentView = nil
            host.removeFromSuperview(); window.close()
        }
        defer { closeWindow() }
        // 给 SwiftUI 的任务及原生材质两次显示周期；等待只服务审核工具，不进入产品交互路径。
        for _ in 0..<2 {
            host.layoutSubtreeIfNeeded(); stage.layoutSubtreeIfNeeded()
            window.displayIfNeeded(); CATransaction.flush()
            try await Task.sleep(for: .milliseconds(160))
        }
        prepareFrame?()
        host.layoutSubtreeIfNeeded(); stage.displayIfNeeded(); CATransaction.flush()
        let backdropCounts = countBackdrops(in: host)
        let backdropCount = backdropCounts.withinWindow + backdropCounts.behindWindow
        guard backdropCounts.behindWindow == 0 else { throw ReviewError.failed("\(name) 审核仍有跨窗口背景采样") }
        if configuration.mode == .standard && backdropCount == 0 {
            throw ReviewError.failed("\(name) 缺少原生背景材质视图")
        }
        if configuration.mode != .standard && backdropCount > 0 {
            throw ReviewError.failed("\(name) 辅助功能回退仍保留背景采样")
        }
        guard let bitmap = stage.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw ReviewError.failed("无法创建 \(name) 位图")
        }
        stage.cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ReviewError.failed("无法输出 \(name) PNG")
        }
        let samples = probe ? probeSamples(bitmap: bitmap, bounds: bounds) : nil
        let filename = "material-\(name)-\(configuration.suffix).png"
        let url = output.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        print(url.path)
        closeWindow()
        guard !window.isVisible, window.contentView == nil, host.superview == nil else { throw ReviewError.failed("\(name) 审核窗口未正确关闭") }
        return OutputRecord(file: filename, scene: name, background: configuration.background.rawValue, appearance: configuration.dark ? "dark" : "light",
                            mode: configuration.mode.rawValue, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
                            nativeBackdropCount: backdropCount, withinWindowBackdropCount: backdropCounts.withinWindow,
                            behindWindowBackdropCount: backdropCounts.behindWindow, windowClosedAndDetached: true, probeSamples: samples)
    }

    private static func makeWindow(size: CGSize, appearance: NSAppearance.Name) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.hasShadow = false
        window.isOpaque = false; window.backgroundColor = .clear
        window.appearance = NSAppearance(named: appearance)
        return window
    }

    private static func countBackdrops(in view: NSView) -> (withinWindow: Int, behindWindow: Int) {
        var result = (withinWindow: 0, behindWindow: 0)
        if let effect = view as? NSVisualEffectView,
           effect.identifier?.rawValue == "caplo.material.backdrop" || String(describing: type(of: effect)).contains("PassiveBackdrop") {
            if effect.blendingMode == .withinWindow { result.withinWindow += 1 }
            else { result.behindWindow += 1 }
        }
        for child in view.subviews {
            let counts = countBackdrops(in: child)
            result.withinWindow += counts.withinWindow; result.behindWindow += counts.behindWindow
        }
        return result
    }

    /// 探针中间是穿过玻璃的黑白硬边。近边对比低于远边，才说明缓存位图确实含有柔化结果。
    /// 单纯背景换色不能证明模糊，因此这两个维度分别记录，失败时不制造近似效果来凑图。
    private static func probeSamples(bitmap: NSBitmapImageRep, bounds: CGRect) -> ProbeSamples {
        let sx = Double(bitmap.pixelsWide) / bounds.width, sy = Double(bitmap.pixelsHigh) / bounds.height
        func color(_ x: Double, _ y: Double) -> [Double] {
            guard let color = bitmap.colorAt(x: min(bitmap.pixelsWide - 1, max(0, Int(x * sx))),
                                              y: min(bitmap.pixelsHigh - 1, max(0, Int(y * sy))))?.usingColorSpace(.sRGB) else { return [] }
            return [color.redComponent, color.greenComponent, color.blueComponent]
        }
        let near = difference(color(bounds.midX - 2, bounds.midY), color(bounds.midX + 2, bounds.midY))
        let far = difference(color(bounds.midX - 36, bounds.midY), color(bounds.midX + 36, bounds.midY))
        return ProbeSamples(surfaceColor: color(bounds.midX - 40, bounds.midY + 52), nearEdgeContrast: near,
                            farEdgeContrast: far, includesEdgeSoftening: far > 0.08 && near < far * 0.8)
    }

    private static func difference(_ first: [Double], _ second: [Double]) -> Double {
        guard first.count == 3, second.count == 3 else { return 0 }
        return zip(first, second).map { abs($0.0 - $0.1) }.reduce(0, +) / 3
    }

    private static func probeEvidence(_ records: [OutputRecord]) -> [ProbeEvidence] {
        var result: [ProbeEvidence] = []
        for mode in [Mode.standard, .reducedTransparency, .highContrast] {
            for appearance in ["light", "dark"] {
                let rows = records.filter { $0.scene == "probe" && $0.mode == mode.rawValue && $0.appearance == appearance }
                guard rows.count > 1 else { continue }
                let samples = rows.compactMap(\.probeSamples)
                var maximum = 0.0
                for a in samples { for b in samples { maximum = max(maximum, difference(a.surfaceColor, b.surfaceColor)) } }
                result.append(ProbeEvidence(mode: mode.rawValue, appearance: appearance, maximumBackgroundDifference: maximum,
                    backgroundChangesVisible: maximum > 0.035, opaqueFallbackStable: mode != .standard && maximum < 0.015,
                    bitmapIncludesEdgeSoftening: samples.allSatisfy(\.includesEdgeSoftening)))
            }
        }
        return result
    }

    private enum Mode: String { case standard, reducedTransparency = "reduced-transparency", highContrast = "high-contrast" }
    private struct Configuration {
        let dark: Bool
        let mode: Mode
        let background: Background
        var suffix: String { background.rawValue + "-" + (dark ? "dark" : "light") + (mode == .standard ? "" : "-" + mode.rawValue) }
        var appearance: NSAppearance.Name {
            // accessibilityHighContrast* 只可用于 bestMatch，不能用于构造 NSAppearance。
            // 高对比通过 SwiftUI / AppKit 共用的预览策略显式转发，避免系统静默降级成普通外观。
            dark ? .darkAqua : .aqua
        }
    }
    private struct OutputRecord: Encodable {
        let file: String
        let scene: String
        let background: String
        let appearance: String
        let mode: String
        let width: Int
        let height: Int
        let nativeBackdropCount: Int
        let withinWindowBackdropCount: Int
        let behindWindowBackdropCount: Int
        let windowClosedAndDetached: Bool
        let probeSamples: ProbeSamples?
    }
    private struct ProbeSamples: Encodable {
        let surfaceColor: [Double]
        let nearEdgeContrast: Double
        let farEdgeContrast: Double
        let includesEdgeSoftening: Bool
    }
    private struct ProbeEvidence: Encodable {
        let mode: String
        let appearance: String
        let maximumBackgroundDifference: Double
        let backgroundChangesVisible: Bool
        let opaqueFallbackStable: Bool
        let bitmapIncludesEdgeSoftening: Bool
    }
    private struct Report: Encodable {
        let description: String
        let limitation: String
        let source: String
        let canvasWidth: Int
        let canvasHeight: Int
        let probeOnly: Bool
        let probeEvidence: [ProbeEvidence]
        let outputs: [OutputRecord]
    }
    private enum ReviewError: Error { case failed(String) }
}

/// 暖霞、林间和夜幕只控制环境颜色，玻璃的中性填色始终由生产设计系统决定。
private enum Background: String, CaseIterable { case dusk, meadow, night }

/// 自绘低频色域和清晰丝带供观察玻璃背景采样；没有壁纸文件或任何桌面采集。
@MainActor
private final class EnvironmentView: NSView {
    private let background: Background
    private let probe: Bool
    init(frame: CGRect, background: Background, probe: Bool) {
        self.background = background; self.probe = probe
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let palette: [NSColor]
        switch background {
        case .dusk: palette = [color(0.35, 0.25, 0.31), color(0.57, 0.40, 0.30), color(0.18, 0.28, 0.23)]
        case .meadow: palette = [color(0.18, 0.34, 0.32), color(0.54, 0.55, 0.33), color(0.12, 0.29, 0.31)]
        case .night: palette = [color(0.14, 0.17, 0.31), color(0.32, 0.33, 0.46), color(0.07, 0.16, 0.22)]
        }
        NSGradient(colors: palette)?.draw(in: bounds, angle: -35)
        let center = CGPoint(x: bounds.width * 0.35, y: bounds.height * 0.84)
        NSGradient(starting: color(0.9, 0.91, 0.87, 0.1), ending: .clear)?.draw(
            fromCenter: center, radius: 0, toCenter: center, radius: max(bounds.width, bounds.height) * 0.72,
            options: [.drawsAfterEndingLocation])
        let ribbon = NSBezierPath()
        ribbon.move(to: CGPoint(x: bounds.width * 0.1, y: -bounds.height * 0.2))
        ribbon.curve(to: CGPoint(x: bounds.width * 0.68, y: bounds.height * 1.2),
                     controlPoint1: CGPoint(x: bounds.width * 0.9, y: bounds.height * 0.3),
                     controlPoint2: CGPoint(x: bounds.width * 0.05, y: bounds.height * 0.7))
        color(1, 1, 1, 0.07).setStroke(); ribbon.lineWidth = max(20, bounds.width * 0.06); ribbon.stroke()
        color(1, 1, 1, 0.17).setStroke(); ribbon.lineWidth = 1; ribbon.stroke()
        if probe {
            // 横跨整个窗口的硬边同时提供玻璃内外对照；距中心 52pt 的环境色采样避开此条。
            color(0.08, 0.08, 0.08).setFill()
            CGRect(x: 0, y: bounds.midY - 16, width: bounds.midX, height: 32).fill()
            color(0.92, 0.92, 0.92).setFill()
            CGRect(x: bounds.midX, y: bounds.midY - 16, width: bounds.midX, height: 32).fill()
        }
    }

    private func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

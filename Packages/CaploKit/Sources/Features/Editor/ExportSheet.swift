import AppKit
import SwiftUI
import CaploDesignSystem
import ExportKit

/// 导出窗口：格式、分辨率、帧率、画质、声音、保存位置与导出后的动作，底部一行写清最终参数和预计大小。
/// 分辨率从编辑器顶栏挪到这里（2026-10-06）：它只在导出时有意义，常驻顶栏只会被误以为是预览分辨率。
/// 保存位置默认取设置页里的文件夹，这里随时可以另选（"选择…"）；同名文件先提示、点导出时再确认替换。
struct ExportSheet: View {
    let model: VideoEditorModel
    @State private var settings: ExportSettings
    @State private var fileName: String
    @State private var folder: URL
    @State private var remember: Bool

    init(model: VideoEditorModel) {
        self.model = model
        _settings = State(initialValue: model.exportSettings)
        _fileName = State(initialValue: ExportSettings.sanitizedFileName(model.entry.document.name) ?? "导出")
        _folder = State(initialValue: ExportSettings.defaultFolder())
        _remember = State(initialValue: ExportSettings.remembersChoices())
    }

    /// 最终文件：文件夹 + 文件名 + 随格式变化的扩展名。名字不合法（空、以点开头）时为 nil，导出按钮灰掉。
    private var destination: URL? {
        ExportSettings.sanitizedFileName(fileName).map { folder.appendingPathComponent($0).appendingPathExtension(settings.format.fileExtension) }
    }
    private var destinationExists: Bool { destination.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    private var recordedFrameRate: Double { model.entry.document.frameRate }
    private var ratio: CanvasRatio { model.edit.layout.ratio }
    private var size: (width: Int, height: Int) { settings.outputSize(ratio: ratio) }
    private var frameRate: Double { settings.outputFrameRate(recorded: recordedFrameRate) }

    var body: some View {
        VStack(alignment: .leading, spacing: CaploMetrics.Spacing.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text("导出").font(CaploFont.panelTitle).foregroundStyle(CaploColor.textPrimary)
                Text("\(model.entry.document.name) · 时长 \(timecode(model.edit.duration))")
                    .font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary).lineLimit(1).truncationMode(.middle)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: CaploMetrics.Spacing.m, verticalSpacing: CaploMetrics.Spacing.m) {
                row("格式", caption: settings.format.detail) {
                    SelectField(value: settings.format.title, placeholder: "格式", accessibilityName: "导出格式", sections: [
                        SelectField.Section(items: ExportSettings.Format.allCases.map { format in
                            SelectField.Item(id: format.id, title: format.title, checked: format == settings.format) {
                                settings.format = format; settings.normalize()
                            }
                        }),
                    ])
                }
                row("分辨率", caption: "\(size.width) × \(size.height) · 画面比例 \(ratio.rawValue)") {
                    SegmentedBar(ExportSettings.Resolution.options(for: settings.format), selection: $settings.resolution) { $0.title }
                        .accessibilityLabel("分辨率")
                }
                if settings.format == .gif {
                    row("帧率", caption: "动图 15 帧已经连贯；帧率越高，体积越大。") {
                        SegmentedBar(ExportSettings.gifFrameRates, selection: $settings.gifFrameRate) { "\($0) fps" }
                            .accessibilityLabel("帧率")
                    }
                } else {
                    row("帧率", caption: frameRateCaption) {
                        SegmentedBar(ExportSettings.frameRateOptions(recorded: recordedFrameRate),
                                     selection: Binding(get: { settings.frameRate ?? 0 }, set: { settings.frameRate = $0 == 0 ? nil : $0 })) { value in
                            value == 0 ? "原始 \(Int(recordedFrameRate.rounded()))" : "\(value)"
                        }
                        .accessibilityLabel("帧率")
                    }
                }
                if settings.format.hasQuality {
                    row("画质", caption: qualityCaption) {
                        SegmentedBar(ExportSettings.Quality.allCases, selection: $settings.quality) { $0.title }
                            .accessibilityLabel("画质")
                    }
                }
                row("声音", caption: audioCaption) {
                    if settings.format.hasAudio {
                        HStack(spacing: CaploMetrics.Spacing.m) {
                            Toggle("包含声音", isOn: $settings.includesAudio).toggleStyle(StudioToggleStyle()).fixedSize()
                            if settings.includesAudio, settings.format != .proRes {
                                SegmentedBar(ExportSettings.audioBitRates, selection: $settings.audioBitRate) { "\($0 / 1000)" }
                                    .accessibilityLabel("声音码率")
                            }
                        }
                    } else {
                        Text("GIF 没有声音").font(CaploFont.body).foregroundStyle(CaploColor.textSecondary)
                    }
                }
                row("保存到", caption: destinationCaption) {
                    VStack(alignment: .leading, spacing: CaploMetrics.Spacing.xs + 2) {
                        HStack(spacing: CaploMetrics.Spacing.xs) {
                            TextField("文件名", text: $fileName).textFieldStyle(.plain).font(CaploFont.body)
                                .padding(.horizontal, 10).frame(height: CaploMetrics.ControlHeight.medium)
                                .caploMaterial(.raised, cornerRadius: CaploMetrics.Radius.control)
                                .accessibilityLabel("文件名")
                            Text("." + settings.format.fileExtension).font(CaploFont.value).foregroundStyle(CaploColor.textSecondary)
                        }
                        HStack(spacing: CaploMetrics.Spacing.s) {
                            Image(systemName: "folder").foregroundStyle(CaploColor.textSecondary)
                            Text(Self.displayPath(folder)).font(CaploFont.caption).foregroundStyle(CaploColor.textPrimary)
                                .lineLimit(1).truncationMode(.head).help(folder.path)
                            Spacer(minLength: CaploMetrics.Spacing.s)
                            Button("选择…") { chooseFolder() }.buttonStyle(StudioButtonStyle(.secondary, size: .small))
                                .accessibilityLabel("选择保存位置")
                        }
                    }
                }
            }
            summary
            HStack(alignment: .bottom, spacing: CaploMetrics.Spacing.s) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("记住这些设置", isOn: $remember).toggleStyle(.checkbox)
                        .help("格式、分辨率、帧率、画质、声音与这次的保存位置，下次打开导出窗口直接用。不勾则下次回到默认值。")
                    Toggle("完成后在访达中显示", isOn: $settings.revealsInFinder).toggleStyle(.checkbox)
                        .onChange(of: settings.revealsInFinder) { _, value in UserDefaults.standard.set(value, forKey: ExportSettings.revealKey) }
                }
                .font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
                Spacer()
                Button("取消") { model.showingExport = false }.buttonStyle(StudioButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
                Button("导出") { confirmAndExport() }.buttonStyle(StudioButtonStyle(.primary)).keyboardShortcut(.defaultAction)
                    .disabled(!model.ready || model.edit.duration <= 0 || destination == nil)
            }
        }
        .padding(CaploMetrics.Spacing.xl).frame(width: 500)
        // 点弹窗外面等于"取消"，设置不记。
        .onOutsideClick { model.showingExport = false }
        .foregroundStyle(CaploColor.textPrimary)
        .background(CaploMaterialBackground(.window))
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
    }

    private var destinationCaption: String? {
        guard destination != nil else { return "请输入文件名。" }
        return destinationExists ? "这个位置已有同名文件，导出时会先问你是否替换。" : nil
    }

    /// 另选保存位置（只影响这一次；勾着"记住这些设置"时它会成为下次的默认位置）。
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "选择"; panel.message = "选择导出文件的保存位置"
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    /// 已有同名文件先确认替换，再开始导出。
    private func confirmAndExport() {
        guard let destination else { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            let alert = NSAlert()
            alert.messageText = "替换“\(destination.lastPathComponent)”？"
            alert.informativeText = "这个位置已有同名文件。替换后原文件会被新导出的文件覆盖。"
            alert.addButton(withTitle: "替换")
            alert.addButton(withTitle: "取消")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.startExport(settings, to: destination, remember: remember)
    }

    /// 路径里的主目录写成 ~，长路径从开头截断（文件夹名在末尾，最要紧）。
    static func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// 一行参数：左侧标题，右侧控件，控件下方一行说明。
    @ViewBuilder private func row<Content: View>(_ title: String, caption: String?, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(title).font(CaploFont.body).foregroundStyle(CaploColor.textSecondary).gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 5) {
                content()
                if let caption {
                    Text(caption).font(CaploFont.caption).foregroundStyle(CaploColor.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 最终参数一行写全，再加预计大小：导出前看一眼就知道会得到什么。
    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summaryLine).font(CaploFont.value).foregroundStyle(CaploColor.textPrimary).fixedSize(horizontal: false, vertical: true)
            Text(sizeLine).font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
        }
        .padding(CaploMetrics.Spacing.m).frame(maxWidth: .infinity, alignment: .leading)
        .background(CaploColor.surfaceRaised, in: RoundedRectangle(cornerRadius: CaploMetrics.Radius.control, style: .continuous))
    }

    private var summaryLine: String {
        var parts = ["\(size.width) × \(size.height)", "\(Int(frameRate.rounded())) fps"]
        switch settings.format {
        case .h264: parts.append("H.264")
        case .hevc: parts.append("HEVC")
        case .proRes: parts.append("ProRes 422")
        case .gif: parts.append("GIF")
        }
        if let bitRate = settings.videoBitRate(width: size.width, height: size.height, frameRate: frameRate) { parts.append(Self.megabits(bitRate)) }
        if settings.format.hasAudio {
            parts.append(!settings.includesAudio ? "无声" : settings.format == .proRes ? "PCM 24 位" : "AAC \(settings.audioBitRate / 1000) kbps")
        }
        return parts.joined(separator: " · ")
    }

    private var sizeLine: String {
        guard let bytes = settings.estimatedBytes(ratio: ratio, recordedFrameRate: recordedFrameRate, duration: model.edit.duration) else {
            return "GIF 的体积随画面变化，动得越多越大；较长的演示建议导出 MP4。"
        }
        return "预计约 " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var frameRateCaption: String {
        let output = Int(frameRate.rounded())
        if settings.resolution == .p2160, recordedFrameRate > 60.5 { return "4K 最高 60 fps，将以 \(output) fps 导出。" }
        return settings.frameRate == nil ? "与录制相同（\(output) fps），动作最流畅。" : "以 \(output) fps 导出，体积更小。"
    }

    private var qualityCaption: String {
        let rate = settings.videoBitRate(width: size.width, height: size.height, frameRate: frameRate).map(Self.megabits) ?? ""
        switch settings.quality {
        case .standard: return "约 \(rate)，静态界面为主时看不出差别。"
        case .high: return "约 \(rate)，文字与细线清晰，推荐。"
        case .maximum: return "约 \(rate)，大量滚动与细小文字时选它。"
        }
    }

    private var audioCaption: String? {
        guard settings.format.hasAudio, settings.includesAudio else { return nil }
        return settings.format == .proRes ? "ProRes 的声音按 24 位 PCM 写入，不再有损压缩。" : "AAC 码率（kbps），256 对讲解与系统声音都足够。"
    }

    private static func megabits(_ bitRate: Int) -> String {
        let value = Double(bitRate) / 1_000_000
        return value >= 10 ? "\(Int(value.rounded())) Mbps" : String(format: "%.1f Mbps", value)
    }
}

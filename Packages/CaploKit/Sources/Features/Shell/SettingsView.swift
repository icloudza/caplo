import SwiftUI
import AppKit
import CaploDesignSystem
import CaptureKit
import ProjectKit
import ExportKit

/// 设置：左侧栏（录制 / 导出 / 存储 / 快捷键 / 关于）+ 右侧分组卡片，680×460 固定窗口。
/// 内容延伸到标题栏之下，红黄绿落在侧栏顶部；每个设置项一行，说明写在标题下面，控件靠右。
public struct CaploSettingsView: View {
    public static let size = CGSize(width: 680, height: 460)
    static let sidebarWidth: CGFloat = 176

    enum Section: String, CaseIterable, Identifiable {
        case recording = "录制", export = "导出", storage = "存储", shortcuts = "快捷键", about = "关于"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .recording: "record.circle"; case .export: "square.and.arrow.up"; case .storage: "internaldrive"
            case .shortcuts: "keyboard"; case .about: "info.circle"
            }
        }
    }

    @AppStorage("recording.countdown") private var countdown = 3
    @AppStorage("recording.frameRate") private var frameRate = 60
    @AppStorage("recording.microphone") private var microphone = false
    @AppStorage("recording.systemAudio") private var systemAudio = false
    @AppStorage("recording.camera") private var camera = false
    @AppStorage(ExportSettings.revealKey) private var revealAfterExport = true
    @State private var section: Section = .recording
    @State private var externalProjects = 0
    @State private var exportFolder = ExportSettings.defaultFolder()
    @State private var customExportFolder = ExportSettings.hasCustomFolder()
    @State private var rememberExport = ExportSettings.remembersChoices()
    @State private var rememberedExport = ExportSettings.hasRememberedSettings()

    public init() {}
    /// 离屏预览直接打开到某一页（按侧栏标题）。
    public init(previewSection title: String) { _section = State(initialValue: Section(rawValue: title) ?? .recording) }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(CaploColor.separator).frame(width: CaploMetrics.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: CaploMetrics.Spacing.xl) {
                    Text(section.rawValue).font(CaploFont.panelTitle).foregroundStyle(CaploColor.textPrimary)
                        .padding(.top, CaploMetrics.compactTitleBarHeight - CaploMetrics.Spacing.s)
                    switch section {
                    case .recording: recording
                    case .export: export
                    case .storage: storage
                    case .shortcuts: shortcuts
                    case .about: about
                    }
                }
                .padding(.horizontal, CaploMetrics.Spacing.xl)
                .padding(.bottom, CaploMetrics.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(CaploMaterialBackground(.window))
        .foregroundStyle(CaploColor.textPrimary)
        .tint(CaploColor.accent)
        .preferredColorScheme(.dark)
        .onAppear {
            externalProjects = UserDefaults.standard.stringArray(forKey: "externalProjects")?.count ?? 0
            // 导出窗口可能刚改过默认位置与记住的参数：每次打开设置页重读。
            exportFolder = ExportSettings.defaultFolder(); customExportFolder = ExportSettings.hasCustomFolder()
            rememberExport = ExportSettings.remembersChoices(); rememberedExport = ExportSettings.hasRememberedSettings()
        }
    }

    // MARK: 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 红黄绿占据侧栏顶部 28 点。
            Spacer().frame(height: CaploMetrics.compactTitleBarHeight + CaploMetrics.Spacing.s)
            ForEach(Section.allCases) { item in
                SettingsSidebarItem(item.rawValue, systemImage: item.symbol, selected: section == item) { section = item }
            }
            Spacer(minLength: 0)
            Text("Caplo \(Self.version)").font(CaploFont.caption).foregroundStyle(CaploColor.textTertiary)
                .padding(.horizontal, 10).padding(.bottom, CaploMetrics.Spacing.s)
        }
        .padding(.horizontal, CaploMetrics.Spacing.s)
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(CaploMaterialBackground(.panel))
    }

    // MARK: 录制

    @ViewBuilder private var recording: some View {
        SettingsGroup("画面") {
            SettingsRow("帧率", caption: frameRate == 60 ? "滚动与光标运动更顺滑，文件更大；预览与导出按同一帧率。" : "更省空间，适合静态内容较多的演示。") {
                ChipGroup([30, 60], selection: $frameRate) { "\($0) fps" }
            }
        }
        SettingsGroup("开始录制") {
            SettingsRow("倒计时") {
                ChipGroup([0, 3, 5, 10], selection: $countdown) { $0 == 0 ? "不倒计时" : "\($0) 秒" }
            }
        }
        SettingsGroup("默认输入") {
            SettingsRow("麦克风") { Toggle("麦克风", isOn: $microphone).toggleStyle(StudioToggleStyle(embedded: true)) }
            SettingsRow("系统声音") { Toggle("系统声音", isOn: $systemAudio).toggleStyle(StudioToggleStyle(embedded: true)) }
            SettingsRow("摄像头") { Toggle("摄像头", isOn: $camera).toggleStyle(StudioToggleStyle(embedded: true)) }
        }
    }

    // MARK: 导出

    /// 导出窗口打开时的默认值都在这里：保存位置、记不记导出参数、导出完成后的动作。
    /// 导出窗口里随时可以另选位置；勾着"记住这些设置"导出时，那次的位置与参数会同步到这里。
    @ViewBuilder private var export: some View {
        SettingsGroup("保存位置", footer: "导出窗口里可以随时另选位置；勾着\u{201C}记住这些设置\u{201D}导出时，那次的位置会成为这里的默认位置。") {
            SettingsRow("默认位置", caption: exportFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                HStack(spacing: CaploMetrics.Spacing.s) {
                    Button("更改…") { chooseExportFolder() }.buttonStyle(StudioButtonStyle(.secondary, size: .small))
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([exportFolder]) }
                        .buttonStyle(StudioButtonStyle(.quiet, size: .small))
                }
            }
            if customExportFolder {
                SettingsRow("恢复默认位置", caption: "回到\u{201C}影片\u{201D}文件夹。") {
                    Button("恢复") {
                        ExportSettings.setDefaultFolder(nil)
                        exportFolder = ExportSettings.defaultFolder(); customExportFolder = false
                    }
                    .buttonStyle(StudioButtonStyle(.quiet, size: .small))
                }
            }
        }
        SettingsGroup("导出参数") {
            SettingsRow("记住导出窗口里的选择",
                        caption: !rememberExport ? "每次打开导出窗口都从默认参数开始。"
                            : rememberedExport ? "当前记住：\(ExportSettings.remembered().summary)" : "还没有记住的参数，下次导出时记下。") {
                Toggle("记住导出窗口里的选择", isOn: Binding(get: { rememberExport }, set: { value in
                    rememberExport = value; ExportSettings.setRemembersChoices(value)
                })).toggleStyle(StudioToggleStyle(embedded: true))
            }
            SettingsRow("恢复默认参数", caption: ExportSettings().summary) {
                Button("恢复") { ExportSettings.forget(); rememberedExport = false }
                    .buttonStyle(StudioButtonStyle(.quiet, size: .small)).disabled(!rememberedExport)
            }
        }
        SettingsGroup("导出完成后") {
            SettingsRow("在访达中显示", caption: "导出完成后打开访达并选中导出的文件。") {
                Toggle("在访达中显示", isOn: $revealAfterExport).toggleStyle(StudioToggleStyle(embedded: true))
            }
        }
    }

    private func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "选择"; panel.message = "选择导出文件的默认保存位置"
        panel.directoryURL = exportFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ExportSettings.setDefaultFolder(url)
        exportFolder = ExportSettings.defaultFolder(); customExportFolder = true
    }

    // MARK: 存储

    @ViewBuilder private var storage: some View {
        SettingsGroup("工程", footer: "默认保存在应用支持目录。") {
            SettingsRow("保存位置", caption: ProjectStoragePaths.libraryDescription) {
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([ProjectStoragePaths.libraryURL]) }
                    .buttonStyle(StudioButtonStyle(.secondary, size: .small))
            }
            SettingsRow("外部工程记录", caption: externalProjects == 0 ? "通过\u{201C}打开工程…\u{201D}打开过的工程会记在这里，并出现在项目中心。" : "已记录 \(externalProjects) 个其他位置的工程，它们会出现在项目中心。") {
                Button("清除记录") {
                    UserDefaults.standard.set([String](), forKey: "externalProjects")
                    externalProjects = 0
                }
                .buttonStyle(StudioButtonStyle(.quiet, size: .small)).disabled(externalProjects == 0)
            }
        }
    }

    // MARK: 快捷键

    @ViewBuilder private var shortcuts: some View {
        SettingsGroup("全局") {
            shortcutRows([("新建录制", "⌘N"), ("打开工程…", "⌘O"), ("项目中心", "⇧⌘P"), ("设置", "⌘,")])
        }
        SettingsGroup("录制方式条", footer: "首次使用引导只在第一次打开录制方式条时出现。") {
            shortcutRows([("全屏 / 自定义区域 / 窗口", "1 / 2 / 3"), ("关闭", "Esc")])
            HStack {
                Text("首次使用引导").font(CaploFont.body)
                Spacer()
                Button("重新显示") { OnboardingTour.reset(); StudioWindows.showRecorder() }.buttonStyle(StudioButtonStyle(.secondary, size: .small))
            }
        }
        SettingsGroup("项目中心") {
            shortcutRows([("搜索", "⌘F"), ("全选", "⌘A"), ("打开选中", "回车"), ("删除选中", "⌫")])
        }
        SettingsGroup("编辑器") {
            shortcutRows([("切换面板", "⌘1 – ⌘9"), ("播放 / 暂停", "空格"), ("分割", "⌘B"), ("撤销 / 重做", "⌘Z / ⇧⌘Z"),
                          ("复制片段", "⌘D"), ("全选片段", "⌘A"), ("导出", "⌘E"), ("逐帧定位", "← / →，⇧ 跳 10 帧"), ("删除选中", "⌫"),
                          ("缩放时间线", "⌥ 滚轮"), ("纵向浏览轨道", "滚轮"), ("横向平移时间线", "⇧ 滚轮"), ("临时关闭吸附", "拖动时按住 ⌥")])
        }
    }

    @ViewBuilder private func shortcutRows(_ rows: [(String, String)]) -> some View {
        ForEach(rows, id: \.0) { title, keys in
            HStack {
                Text(title).font(CaploFont.body).foregroundStyle(CaploColor.textPrimary)
                Spacer()
                KeyCaps(keys)
            }
            .padding(.horizontal, CaploMetrics.Spacing.l)
            .frame(height: 36)
        }
    }

    // MARK: 关于

    @ViewBuilder private var about: some View {
        HStack(spacing: CaploMetrics.Spacing.l) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("Caplo").font(.system(size: 20, weight: .semibold)).foregroundStyle(CaploColor.textPrimary)
                Text("屏幕录制与编辑").font(CaploFont.body).foregroundStyle(CaploColor.textSecondary)
            }
        }
        SettingsGroup {
            SettingsRow("版本") { Text(Self.version).font(CaploFont.value).foregroundStyle(CaploColor.textSecondary) }
            SettingsRow("构建") { Text(Self.build).font(CaploFont.value).foregroundStyle(CaploColor.textSecondary) }
            SettingsRow("系统要求") { Text("macOS 15 及以上").font(CaploFont.value).foregroundStyle(CaploColor.textSecondary) }
        }
    }

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—" }
}

/// 设置页展示的库路径，避免直接依赖 ProjectKit 的内部细节。
enum ProjectStoragePaths {
    static var libraryURL: URL { ProjectStorage.libraryURL }
    static var libraryDescription: String { libraryURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
}

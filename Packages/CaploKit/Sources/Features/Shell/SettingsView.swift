import SwiftUI
import AppKit
import CaploDesignSystem
import CaptureKit
import ProjectKit
import ExportKit

/// 设置：左侧栏（通用 / 录制 / 导出 / 存储 / 快捷键 / 关于）+ 右侧分组卡片，680×460 固定窗口。
/// 内容延伸到标题栏之下，红黄绿落在侧栏顶部；每个设置项一行，说明写在标题下面，控件靠右。
public struct CaploSettingsView: View {
    public static let size = CGSize(width: 680, height: 460)
    static let sidebarWidth: CGFloat = 176

    enum Section: String, CaseIterable, Identifiable {
        case general = "通用", recording = "录制", export = "导出", storage = "存储", shortcuts = "快捷键", about = "关于"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .general: "gearshape"; case .recording: "record.circle"; case .export: "square.and.arrow.up"; case .storage: "internaldrive"
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
    @State private var section: Section = .general
    @State private var launchAtLogin = AppPresence.loginItemState
    @State private var loginItemError: String?
    @AppStorage(AppPresence.hidesDockIconKey) private var hidesDockIcon = false
    @State private var externalProjects = 0
    @State private var exportFolder = ExportSettings.defaultFolder()
    @State private var customExportFolder = ExportSettings.hasCustomFolder()
    @State private var rememberExport = ExportSettings.remembersChoices()
    @State private var rememberedExport = ExportSettings.hasRememberedSettings()
    @State private var recordingShortcut: ShortcutAction?
    @State private var shortcutProblem: (ShortcutAction, String)?
    private let shortcutStore = ShortcutStore.shared
    private let updater = AppUpdater.shared

    public init() {}
    /// 离屏预览直接打开到某一页（按侧栏标题）。
    public init(previewSection title: String) { _section = State(initialValue: Section(rawValue: title) ?? .general) }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(CaploColor.separator).frame(width: CaploMetrics.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: CaploMetrics.Spacing.xl) {
                    Text(section.rawValue).font(CaploFont.panelTitle).foregroundStyle(CaploColor.textPrimary)
                        .padding(.top, CaploMetrics.compactTitleBarHeight - CaploMetrics.Spacing.s)
                    switch section {
                    case .general: general
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
            // 登录项可能在系统设置里被改过：每次打开重读系统状态。
            launchAtLogin = AppPresence.loginItemState
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

    // MARK: 通用

    @ViewBuilder private var general: some View {
        SettingsGroup("启动") {
            SettingsRow("登录时启动", caption: loginCaption) {
                Toggle("登录时启动", isOn: Binding(get: { launchAtLogin != .off && launchAtLogin != .unavailable }, set: { on in
                    loginItemError = AppPresence.setLaunchesAtLogin(on)
                    launchAtLogin = AppPresence.loginItemState
                }))
                .toggleStyle(StudioToggleStyle(embedded: true))
                .disabled(launchAtLogin == .unavailable)
            }
            if launchAtLogin == .needsApproval {
                SettingsRow("需要系统授权", caption: "在登录项中允许 Caplo。") {
                    Button("打开登录项") { AppPresence.openLoginItemsSettings() }.buttonStyle(StudioButtonStyle(.secondary, size: .small))
                }
            }
        }
        SettingsGroup("外观", footer: "编辑器、项目中心或设置打开时临时显示。") {
            SettingsRow("隐藏 Dock 图标", caption: "仅在菜单栏显示。") {
                Toggle("隐藏 Dock 图标", isOn: Binding(get: { hidesDockIcon }, set: { AppPresence.hidesDockIcon = $0 }))
                    .toggleStyle(StudioToggleStyle(embedded: true))
            }
        }
        // 自动检查 / 自动安装只在发布包里有意义；"检查更新"按钮在"关于"页。
        if updater.isEnabled {
            SettingsGroup("更新") {
                SettingsRow("自动检查更新", caption: lastCheckCaption) {
                    Toggle("自动检查更新", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.setAutomaticallyChecks($0) }))
                        .toggleStyle(StudioToggleStyle(embedded: true))
                }
                SettingsRow("自动下载并安装", caption: "退出 Caplo 时安装。") {
                    Toggle("自动下载并安装", isOn: Binding(get: { updater.automaticallyDownloads }, set: { updater.setAutomaticallyDownloads($0) }))
                        .toggleStyle(StudioToggleStyle(embedded: true))
                        .disabled(!updater.automaticallyChecks)
                }
            }
        }
    }

    private var lastCheckCaption: String {
        guard let date = updater.lastCheck else { return "每天检查一次。" }
        return "上次检查：" + date.formatted(.relative(presentation: .named).locale(Locale(identifier: "zh_CN")))
    }

    private var loginCaption: String {
        if let loginItemError { return loginItemError }
        switch launchAtLogin {
        case .unavailable: return "请将 Caplo 移到\u{201C}应用程序\u{201D}文件夹后再试。"
        default: return "登录后在菜单栏待命。"
        }
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
                    Button("更改") { chooseExportFolder() }.buttonStyle(StudioButtonStyle(.secondary, size: .small))
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
            SettingsRow("外部工程记录", caption: externalProjects == 0 ? "通过\u{201C}打开工程\u{201D}打开过的工程会记在这里，并出现在项目中心。" : "已记录 \(externalProjects) 个其他位置的工程，它们会出现在项目中心。") {
                Button("清除记录") {
                    UserDefaults.standard.set([String](), forKey: "externalProjects")
                    externalProjects = 0
                }
                .buttonStyle(StudioButtonStyle(.quiet, size: .small)).disabled(externalProjects == 0)
            }
        }
    }

    // MARK: 快捷键

    /// 可改的动作一行一个改键框；方向键、删除、Esc、回车、⌘1–⌘9 与滚轮手势是固定约定，单列在"固定"里只读展示。
    @ViewBuilder private var shortcuts: some View {
        SettingsGroup("全局", footer: "需包含 ⌘ 或 ⌃。") {
            editableRows([.newRecording, .openProject, .projectLibrary, .settings])
        }
        SettingsGroup("录制方式条") {
            editableRows([.recordDisplay, .recordRegion, .recordWindow])
            // 用标准设置行：原来是裸 HStack，没有行内边距与行高，标题顶到卡片左缘、按钮贴着右边框。
            SettingsRow("首次使用引导", caption: "只在第一次打开录制方式条时出现。") {
                Button("重新显示") { OnboardingTour.reset(); StudioWindows.showRecorder() }.buttonStyle(StudioButtonStyle(.secondary, size: .small))
            }
        }
        SettingsGroup("项目中心") {
            editableRows([.librarySearch, .librarySelectAll])
        }
        SettingsGroup("编辑器") {
            editableRows([.playPause, .split, .undo, .redo, .duplicate, .selectAllClips, .export])
        }
        SettingsGroup("固定", footer: "系统通用约定，不可修改。") {
            shortcutRows([("关闭录制方式条 / 取消", "Esc"), ("打开选中的项目", "回车"), ("删除选中", "⌫"), ("切换编辑器面板", "⌘1 – ⌘9"),
                          ("逐帧定位", "← / →，⇧ 跳 10 帧"), ("缩放时间线", "⌥ 滚轮"), ("纵向浏览轨道", "滚轮"), ("横向平移时间线", "⇧ 滚轮"),
                          ("临时关闭吸附", "拖动时按住 ⌥")])
        }
        HStack {
            Spacer()
            Button("全部恢复默认") { shortcutStore.resetAll(); recordingShortcut = nil; shortcutProblem = nil }
                .buttonStyle(StudioButtonStyle(.quiet, size: .small)).disabled(!shortcutStore.isCustomized)
        }
    }

    @ViewBuilder private func editableRows(_ actions: [ShortcutAction]) -> some View {
        ForEach(actions) { action in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: CaploMetrics.Spacing.s) {
                    Text(action.title).font(CaploFont.body).foregroundStyle(CaploColor.textPrimary)
                    Spacer()
                    // 改过的键旁边给一个回到默认的小按钮；没改过就不占位置。
                    if shortcutStore.combo(action) != action.defaultCombo {
                        Button { shortcutStore.reset(action); if shortcutProblem?.0 == action { shortcutProblem = nil } } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(StudioIconButtonStyle(size: .small))
                        .help("恢复 \(action.defaultCombo.display)").accessibilityLabel("恢复\(action.title)的默认快捷键")
                    }
                    ShortcutRecorderField(action: action, recording: $recordingShortcut, problem: $shortcutProblem)
                }
                if let problem = shortcutProblem, problem.0 == action {
                    Text(problem.1).font(CaploFont.caption).foregroundStyle(CaploColor.warning)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, CaploMetrics.Spacing.l)
            .padding(.vertical, 6)
            .frame(minHeight: 36)
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
            SettingsRow("版本", caption: updater.isEnabled ? lastCheckCaption : "开发版不检查更新。") {
                HStack(spacing: CaploMetrics.Spacing.m) {
                    Text(Self.version).font(CaploFont.value).foregroundStyle(CaploColor.textSecondary)
                    Button(updater.pendingVersion.map { "安装 \($0)" } ?? "检查更新") { updater.checkForUpdates() }
                        .buttonStyle(StudioButtonStyle(.secondary, size: .small))
                        .disabled(!updater.isEnabled || (!updater.canCheck && updater.pendingVersion == nil))
                }
            }
            SettingsRow("构建") { Text(Self.build).font(CaploFont.value).foregroundStyle(CaploColor.textSecondary) }
            SettingsRow("权限", caption: "屏幕录制、麦克风、摄像头、语音识别") {
                Button("查看") { PermissionsWindow.shared.show(.standalone) }.buttonStyle(StudioButtonStyle(.secondary, size: .small))
            }
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

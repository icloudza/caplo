import SwiftUI
import AppKit
import CaptureKit
import CaploDesignSystem

/// 启动入口：贴在 Dock 上方的浮动条，与录制条同一构件（56 点、圆角 14、HUD 玻璃）：
/// × ｜ 全屏 ｜ 自定义区域 ｜ 窗口 ｜ 项目中心 ｜ 设置。只有点击方式才枚举来源和触发系统权限。
/// 全屏直接取主显示器；窗口在屏幕上悬停点选；区域在鼠标所在屏幕拖拽框选。选定后录制条替换到同一位置。
public struct ModePickerView: View {
    /// 高度 = 错误提示行 24 + 间距 8 + 浮动条 56 + 面板留白 12，与录制条面板一致，贴底后两根条落在同一位置。
    public static let size = CGSize(width: 520, height: 100)
    private let recorder = ScreenRecorder.shared
    @State private var busy = false
    /// 悬停高亮是一块会滑动的底：从一个方式移到另一个方式时平滑过去，离开整组才淡出。
    @State private var hoveredMode: RecordingMode?
    @State private var highlightMode: RecordingMode = .display
    @Namespace private var segmentSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        VStack(alignment: .center, spacing: CaploMetrics.Spacing.s) {
            Spacer(minLength: 0)
            if let error = recorder.errorMessage {
                HStack(spacing: CaploMetrics.Spacing.xs + 2) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(error).lineLimit(1).truncationMode(.tail)
                }
                .font(CaploFont.caption).foregroundStyle(CaploColor.warning)
                .padding(.horizontal, CaploMetrics.Spacing.m).frame(height: 24)
                .caploMaterial(.floating, cornerRadius: 12)
            }
            FloatingBar {
                Button { StudioWindows.hideRecorder() } label: { Image(systemName: "xmark") }
                    .buttonStyle(StudioIconButtonStyle(size: .small))
                    .help("关闭").accessibilityLabel("关闭录制方式")
                    .keyboardShortcut(.cancelAction)
                    .onboardingTarget("close")
                HStack(spacing: CaploMetrics.Spacing.xs) {
                    ForEach(RecordingMode.allCases, id: \.self) { mode in
                        ModeSegment(mode: mode, shortcut: mode.shortcutAction) { pick(mode) }
                            .onboardingTarget(mode.onboardingID)
                            .disabled(busy || recorder.isBusy)
                            .matchedGeometryEffect(id: mode, in: segmentSpace, isSource: true)
                            .onHover { inside in
                                guard inside else { return }
                                withAnimation(CaploMotion.animation(CaploMotion.panel, reduceMotion: reduceMotion)) {
                                    hoveredMode = mode; highlightMode = mode
                                }
                            }
                    }
                }
                .background(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: CaploMetrics.Radius.control + 1)
                        .fill(CaploColor.textPrimary.opacity(0.07))
                        .matchedGeometryEffect(id: highlightMode, in: segmentSpace, isSource: false)
                        .opacity(hoveredMode == nil ? 0 : 1)
                        .allowsHitTesting(false)
                }
                .onHover { inside in
                    guard !inside else { return }
                    withAnimation(CaploMotion.animation(CaploMotion.hover, reduceMotion: reduceMotion)) { hoveredMode = nil }
                }
                .padding(3)
                .background(CaploColor.textPrimary.opacity(0.04), in: RoundedRectangle(cornerRadius: CaploMetrics.Radius.control + 3))
                FloatingBarDivider()
                Button { ProjectLibraryWindow.shared.show() } label: { Image(systemName: "clock.arrow.circlepath") }
                    .buttonStyle(StudioIconButtonStyle()).help("项目中心 \(ShortcutStore.shared.display(.projectLibrary))").accessibilityLabel("项目中心")
                    .onboardingTarget("recent")
                Button { StudioWindows.showSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(StudioIconButtonStyle()).help("设置 \(ShortcutStore.shared.display(.settings))").accessibilityLabel("设置")
                    .onboardingTarget("settings")
            }
            .onboardingTarget("bar")
        }
        .padding(.horizontal, CaploMetrics.floatingBarInset)
        .padding(.bottom, CaploMetrics.floatingBarInset)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .bottom)
        .foregroundStyle(CaploColor.textPrimary)
        .tint(CaploColor.accent)
        .preferredColorScheme(.dark)
    }

    private func pick(_ mode: RecordingMode) {
        guard !busy else { return }
        // 屏幕录制未授权：打开权限窗口并高亮这一项，代替系统询问框与报错文字。
        PermissionCenter.shared.refresh()
        if PermissionsWindow.enforced, !PermissionCenter.shared.screenGranted {
            PermissionsWindow.shared.show(.standalone, focus: .screen); return
        }
        busy = true
        Task {
            defer { busy = false }
            await recorder.refreshSources()
            // 预检说已授权、实际仍读不到（授权后还没重新打开应用）：同样交给权限窗口，那里有"重新打开"。
            if recorder.errorMessage != nil, PermissionsWindow.enforced {
                recorder.dismissError()
                PermissionCenter.shared.markScreenNeedsRelaunch()
                PermissionsWindow.shared.show(.standalone, focus: .screen)
                return
            }
            guard recorder.errorMessage == nil else { return }
            switch mode {
            case .display:
                let model = RecordBarModel(mode: .display)
                await model.refreshSources()
                if model.source != nil { StudioWindows.showRecordBar(model) }
            case .window:
                StudioWindows.hideRecorder()
                if let source = await WindowPicker.pick(from: recorder.sources) {
                    StudioWindows.showRecordBar(RecordBarModel(mode: .window, source: source), focusTarget: true)
                } else { StudioWindows.showRecorder() }
            case .region:
                StudioWindows.hideRecorder()
                StudioWindows.beginRegionSelection()
            }
        }
    }
}

/// 方式分段项：图标 + 名称，30 点高；悬停底由外层的滑动高亮统一绘制，这里只画键盘焦点描边；按快捷键表（默认数字键）直接选择。
struct ModeSegment: View {
    let mode: RecordingMode
    let shortcut: ShortcutAction
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: CaploMetrics.Spacing.xs + 2) {
                Image(systemName: mode.symbol).font(.system(size: 13, weight: .medium)).frame(width: CaploMetrics.Icon.control)
                Text(mode.title).font(CaploFont.bodyMedium).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .foregroundStyle(CaploColor.textPrimary)
            .overlay(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control + 1).strokeBorder(CaploColor.accent.opacity(focused ? 0.9 : 0), lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control + 1))
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .shortcut(shortcut)
        .focused($focused)
        .focusEffectDisabled()
        .help("\(mode.hint) \(ShortcutStore.shared.display(shortcut))")
        .accessibilityLabel("\(mode.title)录制，\(mode.hint)")
    }
}

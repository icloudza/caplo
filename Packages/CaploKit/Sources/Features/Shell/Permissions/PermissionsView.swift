import AppKit
import SwiftUI
import CaploDesignSystem

/// 权限窗口：一张卡片列出 Caplo 用到的权限，每行一个状态与一个动作。
/// 屏幕录制必需，其余可选（用到对应功能时才需要）；授权后行内即时变成"已允许"。
struct PermissionsView: View {
    let center: PermissionCenter
    /// 主按钮文字：启动时"开始使用"，其余场合"完成"。
    var continueTitle = String(localized: "开始使用")
    /// 主按钮是否要等屏幕录制授权（启动、或因屏幕录制缺失而打开时）。
    var requiresScreen = true
    /// 因某项权限缺失而打开时高亮那一行。
    var focus: PermissionKind?
    var onContinue: () -> Void = {}
    var onLater: () -> Void = {}

    static let size = CGSize(width: 540, height: 420)

    var body: some View {
        VStack(alignment: .leading, spacing: CaploMetrics.Spacing.l) {
            HStack(spacing: CaploMetrics.Spacing.l) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("开始录制前，先完成授权").font(.system(size: 17, weight: .semibold))
                    Text("所有素材只保存在这台 Mac 上。").font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
                }
            }
            VStack(spacing: 0) {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(kind: kind, status: center.status(kind), highlighted: kind == focus,
                                  action: { center.request(kind) }, relaunch: { PermissionCenter.relaunch() })
                    if kind != PermissionKind.allCases.last { StudioDivider().padding(.leading, 56) }
                }
            }
            .background(CaploColor.surfaceRaised, in: RoundedRectangle(cornerRadius: CaploMetrics.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CaploMetrics.Radius.card, style: .continuous).strokeBorder(CaploColor.separator))
            Spacer(minLength: 0)
            HStack(spacing: CaploMetrics.Spacing.s) {
                Text(footnote).font(CaploFont.caption).foregroundStyle(CaploColor.textTertiary)
                Spacer()
                if requiresScreen, !center.screenGranted {
                    Button("稍后") { onLater() }.buttonStyle(StudioButtonStyle(.secondary, size: .medium)).keyboardShortcut(.cancelAction)
                }
                Button(continueTitle) { onContinue() }
                    .buttonStyle(StudioButtonStyle(.primary, size: .medium))
                    .keyboardShortcut(.defaultAction)
                    .disabled(requiresScreen && !center.screenGranted)
            }
        }
        .padding(.horizontal, CaploMetrics.Spacing.xl)
        .padding(.top, CaploMetrics.compactTitleBarHeight + CaploMetrics.Spacing.xs)
        .padding(.bottom, CaploMetrics.Spacing.l)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(CaploMaterialBackground(.window))
        .foregroundStyle(CaploColor.textPrimary)
        .tint(CaploColor.accent)
        .preferredColorScheme(.dark)
    }

    private var footnote: String { String(localized: "可随时在系统设置中更改") }
}

private struct PermissionRow: View {
    let kind: PermissionKind
    let status: PermissionStatus
    var highlighted = false
    let action: () -> Void
    var relaunch: () -> Void = {}

    var body: some View {
        HStack(spacing: CaploMetrics.Spacing.m) {
            Image(systemName: kind.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(status == .granted ? CaploColor.live : CaploColor.textSecondary)
                .frame(width: 28, height: 28)
                .background(CaploColor.textPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kind.title).font(CaploFont.bodyMedium)
                    Text(kind.required ? "必需" : "可选")
                        .font(CaploFont.footnote.weight(.medium))
                        .foregroundStyle(kind.required ? CaploColor.record : CaploColor.textTertiary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background((kind.required ? CaploColor.record : CaploColor.textPrimary).opacity(0.12), in: Capsule())
                }
                Text(caption).font(CaploFont.caption).foregroundStyle(captionColor)
            }
            Spacer(minLength: CaploMetrics.Spacing.s)
            trailing
        }
        .padding(.horizontal, CaploMetrics.Spacing.l)
        .frame(minHeight: 60)
        // 因这一项打开窗口时整行淡淡高亮；授权后高亮自然退掉。
        .background(highlighted && status != .granted ? CaploColor.accentSoft : .clear)
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        switch status {
        case .denied where kind == .screen: String(localized: "在系统设置中打开\u{201C}\(PermissionCenter.appName)\u{201D}，再重新打开")
        case .denied: String(localized: "已拒绝，需在系统设置中开启")
        case .needsRelaunch: String(localized: "已开启，重新打开后生效")
        default: kind.purpose
        }
    }

    /// 屏幕录制待生效：说明用中性色（多半是用户还在操作，不是拒绝）。
    private var captionColor: Color {
        status == .denied && kind != .screen ? CaploColor.warning : CaploColor.textSecondary
    }

    @ViewBuilder private var trailing: some View {
        switch status {
        case .granted:
            Label("已允许", systemImage: "checkmark.circle.fill")
                .font(CaploFont.bodyMedium).foregroundStyle(CaploColor.live)
                .labelStyle(.titleAndIcon)
        case .notDetermined:
            Button("允许", action: action).buttonStyle(StudioButtonStyle(kind.required ? .primary : .secondary, size: .small))
        case .denied where kind == .screen:
            // 屏幕录制的开关打开后要重新打开应用才查得到：两步并列给出。
            HStack(spacing: CaploMetrics.Spacing.s) {
                Button("打开设置", action: action).buttonStyle(StudioButtonStyle(.secondary, size: .small))
                Button("重新打开", action: relaunch).buttonStyle(StudioButtonStyle(.primary, size: .small))
            }
        case .denied:
            Button("打开设置", action: action).buttonStyle(StudioButtonStyle(.secondary, size: .small))
        case .needsRelaunch:
            Button("重新打开", action: action).buttonStyle(StudioButtonStyle(.primary, size: .small))
        }
    }
}

/// 离屏预览：按名字给一组状态。
public struct PermissionsPreview: View {
    private let center: PermissionCenter
    private let continueTitle: String
    public init(state: String) {
        switch state {
        case "denied":
            center = PermissionCenter(preview: [.screen: .denied, .microphone: .denied, .camera: .notDetermined, .speech: .notDetermined])
        case "relaunch":
            center = PermissionCenter(preview: [.screen: .needsRelaunch, .microphone: .granted, .camera: .notDetermined, .speech: .notDetermined])
        case "granted":
            center = PermissionCenter(preview: [.screen: .granted, .microphone: .granted, .camera: .granted, .speech: .notDetermined])
        default:
            center = PermissionCenter(preview: [:])
        }
        continueTitle = String(localized: "开始使用")
    }
    public var body: some View { PermissionsView(center: center, continueTitle: continueTitle) }
    public static var size: CGSize { PermissionsView.size }
}

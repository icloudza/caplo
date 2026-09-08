import AppKit
import SwiftUI

/// 录制条上的来源 / 设备下拉："图标 + 当前值 + ▾"，关闭态降低对比并在图标上加斜线。
/// 自绘按钮 + `NSMenu`（见 `PopupMenuEntry`）：标签里的子视图能自己刷新（试听音波），SwiftUI 重绘不会收起菜单。
public struct SourceDropdown: View {
    private let symbol: String
    private let offSymbol: String?
    private let title: String
    private let isOff: Bool
    private let accessibilityName: String
    private let maxTitleWidth: CGFloat?
    private let leading: AnyView?
    private let menu: @MainActor () -> [PopupMenuEntry]
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    @State private var anchor = MenuAnchor()

    /// `leading` 替换前置的符号图标（麦克风试听时的跳动音波）；`menu` 在点击时才构建。
    public init(symbol: String, offSymbol: String? = nil, title: String, isOff: Bool = false, accessibilityName: String, maxTitleWidth: CGFloat? = nil,
                leading: AnyView? = nil, menu: @escaping @MainActor () -> [PopupMenuEntry]) {
        self.symbol = symbol; self.offSymbol = offSymbol; self.title = title; self.isOff = isOff
        self.accessibilityName = accessibilityName; self.maxTitleWidth = maxTitleWidth; self.leading = leading; self.menu = menu
    }

    public var body: some View {
        Button { anchor.popUp(menu(), appearance: .darkAqua) } label: {
            HStack(spacing: CaploMetrics.Spacing.xs + 2) {
                if let leading {
                    leading
                } else {
                    Image(systemName: isOff ? (offSymbol ?? symbol) : symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: CaploMetrics.Icon.control)
                }
                Text(title).font(CaploFont.body).lineLimit(1).truncationMode(.middle).frame(maxWidth: maxTitleWidth)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(CaploColor.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: CaploMetrics.ControlHeight.medium)
            .foregroundStyle(isOff ? CaploColor.textSecondary : CaploColor.textPrimary)
            .background {
                CaploMaterialBackground(.raised)
                    .overlay(CaploColor.glassSheen.opacity(hovered ? 1 : 0))
                    .clipShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control))
            }
            .overlay { CaploGlassBorder(cornerRadius: CaploMetrics.Radius.control) }
            .contentShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control))
        }
        .buttonStyle(PopupButtonStyle())
        .background(MenuAnchorView(anchor: anchor))
        .fixedSize()
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(isOff ? "已关闭" : title)
    }
}

/// 只有图标的下拉（录制条上的齿轮）："图标 + ▾"，高度与 `SourceDropdown` 一致。
public struct IconDropdown: View {
    private let symbol: String
    private let accessibilityName: String
    private let help: String?
    private let menu: @MainActor () -> [PopupMenuEntry]
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    @State private var anchor = MenuAnchor()

    public init(symbol: String, accessibilityName: String, help: String? = nil, menu: @escaping @MainActor () -> [PopupMenuEntry]) {
        self.symbol = symbol; self.accessibilityName = accessibilityName; self.help = help; self.menu = menu
    }

    public var body: some View {
        Button { anchor.popUp(menu(), appearance: .darkAqua) } label: {
            HStack(spacing: CaploMetrics.Spacing.xs) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: CaploMetrics.Icon.control)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(CaploColor.textTertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: CaploMetrics.ControlHeight.medium)
            .foregroundStyle(CaploColor.textPrimary)
            .background {
                CaploMaterialBackground(.raised)
                    .overlay(CaploColor.glassSheen.opacity(hovered ? 1 : 0))
                    .clipShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control))
            }
            .contentShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control))
        }
        .buttonStyle(PopupButtonStyle())
        .background(MenuAnchorView(anchor: anchor))
        .fixedSize()
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        .help(help ?? accessibilityName)
        .accessibilityLabel(accessibilityName)
    }
}

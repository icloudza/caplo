import SwiftUI

/// 设置页的分组卡片：可选的分区标题 + 一张控件层底色的圆角卡片，卡片内每一行之间一条分隔线。
/// 行由 `SettingsRow` 提供；卡片只负责容器与分隔，不关心行里放什么控件。
public struct SettingsGroup<Content: View>: View {
    private let title: String?
    private let footer: String?
    private let content: Content

    public init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.footer = footer; self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CaploMetrics.Spacing.s) {
            if let title {
                Text(title).font(CaploFont.sectionTitle).foregroundStyle(CaploColor.textSecondary)
                    .padding(.horizontal, CaploMetrics.Spacing.xs)
            }
            _VariadicView.Tree(SettingsGroupRows()) { content }
                .background(CaploColor.surfaceRaised, in: RoundedRectangle(cornerRadius: CaploMetrics.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: CaploMetrics.Radius.card, style: .continuous).strokeBorder(CaploColor.separator))
            if let footer {
                Text(footer).font(CaploFont.caption).foregroundStyle(CaploColor.textTertiary)
                    .padding(.horizontal, CaploMetrics.Spacing.xs)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 把卡片里的子视图逐个排开，中间插分隔线；分隔线从行内边距起画，和文字左缘对齐。
private struct SettingsGroupRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != children.last?.id {
                    StudioDivider().padding(.leading, CaploMetrics.Spacing.l)
                }
            }
        }
    }
}

/// 设置行：左侧标题（可带一行说明），右侧放控件；行高不低于 44 点，控件靠右对齐。
public struct SettingsRow<Control: View>: View {
    private let title: String
    private let caption: String?
    private let control: Control

    public init(_ title: String, caption: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title; self.caption = caption; self.control = control()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: CaploMetrics.Spacing.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(CaploFont.body).foregroundStyle(CaploColor.textPrimary)
                if let caption {
                    Text(caption).font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: CaploMetrics.Spacing.m)
            control
        }
        .padding(.horizontal, CaploMetrics.Spacing.l)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

/// 快捷键按键标签：等宽小字压在一块控件层小圆角上，多个键之间留 4 点。
public struct KeyCaps: View {
    private let keys: String
    public init(_ keys: String) { self.keys = keys }
    public var body: some View {
        Text(keys).font(CaploFont.value).foregroundStyle(CaploColor.textPrimary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(CaploColor.textPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(CaploColor.separator))
    }
}

/// 设置侧栏条目：图标 + 名称，选中用强调软底，悬停浅底，键盘焦点强调描边。
public struct SettingsSidebarItem: View {
    private let title: String
    private let symbol: String
    private let selected: Bool
    private let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    public init(_ title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) {
        self.title = title; self.symbol = systemImage; self.selected = selected; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: CaploMetrics.Spacing.s + 2) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                    .frame(width: CaploMetrics.Icon.control + 4)
                    .foregroundStyle(selected ? CaploColor.textPrimary : CaploColor.textSecondary)
                Text(title).font(CaploFont.bodyMedium).foregroundStyle(CaploColor.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(selected ? CaploColor.accentSoft : CaploColor.textPrimary.opacity(hovered ? 0.06 : 0),
                        in: RoundedRectangle(cornerRadius: CaploMetrics.Radius.control + 1))
            .overlay(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control + 1).strokeBorder(CaploColor.accent.opacity(focused ? 0.9 : 0), lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control + 1))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

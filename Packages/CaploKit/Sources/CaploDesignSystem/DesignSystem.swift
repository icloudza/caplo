import SwiftUI
import PlatformSupport

/// 兼容旧调用的快捷入口；数值全部来自 `CaploColor` / `CaploMetrics`，新代码请直接使用令牌。
public enum CaploStyle {
    public static var accent: Color { CaploColor.accent }
    public static let corner: CGFloat = CaploMetrics.Radius.panel
    public static let controlCorner: CGFloat = 7
    public static let spacing: CGFloat = CaploMetrics.Spacing.l
}

/// 旧业务容器接入同一中性玻璃材质，保留类型名兼容调用。
public struct GlassSurface: View {
    private let radius: CGFloat
    public init(radius: CGFloat = CaploStyle.corner) { self.radius = radius }
    public var body: some View {
        CaploMaterialBackground(.panel)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay { CaploGlassBorder(cornerRadius: radius) }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// 统一层级语义：`raised` 为面板层，否则为窗口底层；颜色与材质由设计系统维护。
public struct StudioSurface: View {
    let raised: Bool
    public init(raised: Bool = false) { self.raised = raised }
    public var body: some View {
        CaploMaterialBackground(raised ? .panel : .window)
    }
}

/// 旧按钮样式，映射到 `StudioButtonStyle`；`prominent` 对应主要动作，`compact` 对应小尺寸。
public struct CaploButtonStyle: ButtonStyle {
    private let prominent: Bool
    private let compact: Bool

    /// 紧凑模式用于窄侧栏的图标分组，保留文字尺寸与完整交互状态。
    public init(prominent: Bool = false, compact: Bool = false) { self.prominent = prominent; self.compact = compact }

    public func makeBody(configuration: Configuration) -> some View {
        StudioButtonStyle(prominent ? .primary : .secondary, size: compact ? .medium : .large).makeBody(configuration: configuration)
    }
}

public struct SectionLabel: View {
    private let title: String
    public init(_ title: String) { self.title = title }
    public var body: some View {
        Text(title)
            .font(CaploFont.sectionTitle)
            .foregroundStyle(CaploColor.textSecondary)
            .tracking(1)
    }
}

public struct ChoicePill: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    public init(_ title: String, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(CaploButtonStyle(prominent: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 业务面板的分隔线固定语义颜色；系统菜单仍保留原生分隔行为。
public struct StudioDivider: View {
    private let vertical: Bool
    public init(vertical: Bool = false) { self.vertical = vertical }
    public var body: some View {
        Rectangle().fill(CaploColor.separator)
            .frame(width: vertical ? CaploMetrics.hairline : nil, height: vertical ? nil : CaploMetrics.hairline)
            .accessibilityHidden(true)
    }
}

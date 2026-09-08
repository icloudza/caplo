import SwiftUI

/// 设置项统一使用固定图标槽，避免不同 SF Symbols 的宽度影响文字对齐。
public struct SettingLabel: View {
    private let title: String
    private let symbol: String

    public init(_ title: String, systemImage: String) {
        self.title = title
        self.symbol = systemImage
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(CaploColor.textSecondary)
                .frame(width: 28, height: 28)
                .background(CaploColor.surfaceRaised, in: RoundedRectangle(cornerRadius: CaploMetrics.Radius.control + 2))
                .accessibilityHidden(true)
            Text(title)
                .font(CaploFont.bodyMedium)
                .foregroundStyle(CaploColor.textPrimary)
        }
    }
}

/// 紧凑开关：36×22 轨道，状态颜色来自令牌，并把所有设置行的开关对齐到右侧。
/// `embedded` 为 true 时只画胶囊本身（无标签、无悬停底、无内边距），供 `SettingsRow` 这类已经画好行的容器放在右侧。
public struct CaploToggleStyle: ToggleStyle {
    private let embedded: Bool
    public init(embedded: Bool = false) { self.embedded = embedded }

    public func makeBody(configuration: Configuration) -> some View {
        if embedded { EmbeddedToggleBody(configuration: configuration) }
        else { SettingToggleBody(configuration: configuration) }
    }
}

private struct EmbeddedToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? CaploColor.controlOn : CaploColor.textPrimary.opacity(0.18))
                .overlay { Capsule().strokeBorder(CaploColor.separator) }
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.14), radius: 1, y: 1).padding(3)
                }
                .overlay { Capsule().strokeBorder(CaploColor.accent.opacity(focused ? 0.9 : 0), lineWidth: 2).padding(-3) }
                .frame(width: 36, height: 22)
                .contentShape(Capsule())
                .animation(CaploMotion.animation(CaploMotion.panel, reduceMotion: reduceMotion), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .opacity(enabled ? 1 : 0.4)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

/// 别名，供新代码按组件表命名引用。
public typealias StudioToggleStyle = CaploToggleStyle

private struct SettingToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 16) {
                configuration.label
                Spacer(minLength: 12)
                Capsule()
                    .fill(configuration.isOn ? CaploColor.controlOn : CaploColor.textPrimary.opacity(0.18))
                    .overlay { Capsule().strokeBorder(CaploColor.separator) }
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .frame(width: 16, height: 16)
                            .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
                            .padding(3)
                    }
                    .frame(width: 36, height: 22)
                    .animation(CaploMotion.animation(CaploMotion.panel, reduceMotion: reduceMotion), value: configuration.isOn)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, CaploMetrics.Spacing.s)
            .padding(.vertical, 7)
            .frame(minHeight: 40)
            .background(CaploColor.textPrimary.opacity(hovered && enabled ? 0.04 : 0), in: RoundedRectangle(cornerRadius: CaploMetrics.Radius.card))
            .contentShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.card))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .overlay {
            RoundedRectangle(cornerRadius: CaploMetrics.Radius.card)
                .strokeBorder(CaploColor.accent.opacity(focused ? 0.8 : 0), lineWidth: 2)
                .allowsHitTesting(false)
        }
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        // 自定义绘制不改变辅助功能语义：向 VoiceOver 提供开关名称、状态和切换动作。
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

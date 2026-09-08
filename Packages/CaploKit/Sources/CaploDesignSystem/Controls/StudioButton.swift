import SwiftUI

/// 统一按钮：三种语义、三档高度，覆盖默认 / 悬停 / 按下 / 禁用 / 键盘焦点。
/// 使用：`Button("导出") {}.buttonStyle(StudioButtonStyle(.primary, size: .large))`。
public struct StudioButtonStyle: ButtonStyle {
    /// `destructive` 是红字无底的轻量危险动作；`danger` 是确认弹层里的实心红按钮。
    public enum Kind { case primary, secondary, quiet, destructive, danger }
    public enum Size { case small, medium, large }

    private let kind: Kind
    private let size: Size

    public init(_ kind: Kind = .secondary, size: Size = .medium) {
        self.kind = kind; self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, kind: kind, size: size)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let kind: Kind
        let size: Size
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false
        @FocusState private var focused: Bool

        private var height: CGFloat {
            switch size {
            case .small: CaploMetrics.ControlHeight.small
            case .medium: CaploMetrics.ControlHeight.medium
            case .large: CaploMetrics.ControlHeight.large
            }
        }
        private var horizontalPadding: CGFloat { size == .small ? 8 : 12 }
        private var foreground: Color {
            switch kind {
            case .primary: CaploColor.primaryButtonText
            case .destructive: CaploColor.record
            case .danger: .white
            case .secondary, .quiet: CaploColor.textPrimary
            }
        }
        private var background: Color {
            switch kind {
            case .primary: CaploColor.primaryButtonFill.opacity(configuration.isPressed ? 0.85 : hovered ? 0.92 : 1)
            case .danger: CaploColor.recordFill.opacity(configuration.isPressed ? 0.85 : hovered ? 0.92 : 1)
            case .secondary: CaploColor.surfaceRaised.opacity(configuration.isPressed ? 0.7 : 1)
            case .quiet, .destructive: CaploColor.textPrimary.opacity(configuration.isPressed ? 0.1 : hovered ? 0.06 : 0)
            }
        }

        var body: some View {
            configuration.label
                .font(size == .small ? CaploFont.caption : CaploFont.bodyMedium)
                .lineLimit(1)
                .padding(.horizontal, horizontalPadding)
                .frame(height: height)
                .foregroundStyle(foreground)
                .background {
                    ZStack {
                        if kind == .secondary {
                            CaploMaterialBackground(.raised)
                            CaploColor.glassSheen.opacity(hovered ? 1 : 0)
                            CaploColor.glassShade.opacity(configuration.isPressed ? 1 : 0)
                        } else { background }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: CaploMetrics.Radius.control)
                        .strokeBorder(kind == .secondary ? CaploColor.separator : .clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: CaploMetrics.Radius.control)
                        .strokeBorder(CaploColor.accent.opacity(focused ? 0.9 : 0), lineWidth: 2)
                }
                .opacity(enabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
                .contentShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control))
                .focused($focused)
                .focusEffectDisabled()
                .onHover { hovered = $0 }
                .animation(CaploMotion.animation(CaploMotion.hover, reduceMotion: reduceMotion), value: hovered)
        }
    }
}

/// 只有图标的方形按钮，用于顶栏与工具栏；尺寸随 `Size` 变化，命中区域不小于 24 点。
public struct StudioIconButtonStyle: ButtonStyle {
    public enum Size { case small, medium }
    private let size: Size
    private let active: Bool

    public init(size: Size = .medium, active: Bool = false) { self.size = size; self.active = active }

    public func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, side: size == .small ? 24 : 30, active: active)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let side: CGFloat
        let active: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        @FocusState private var focused: Bool

        var body: some View {
            configuration.label
                .font(.system(size: side > 24 ? 14 : 12, weight: .medium))
                .frame(width: side, height: side)
                .foregroundStyle(active ? CaploColor.accent : CaploColor.textPrimary)
                .background(
                    active ? CaploColor.accentSoft : CaploColor.textPrimary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.07 : 0),
                    in: RoundedRectangle(cornerRadius: CaploMetrics.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control).strokeBorder(CaploColor.accent.opacity(focused ? 0.9 : 0), lineWidth: 2))
                .contentShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control))
                .opacity(enabled ? 1 : 0.4)
                .focused($focused)
                .focusEffectDisabled()
                .onHover { hovered = $0 }
        }
    }
}

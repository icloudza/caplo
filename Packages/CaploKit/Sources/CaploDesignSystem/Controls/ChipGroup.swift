import SwiftUI

/// 单选 chips，用于比例、颜色等少量互斥选项；24 点高，选中态用强调色描边与软底。
public struct ChipGroup<Option: Hashable>: View {
    private let options: [Option]
    @Binding private var selection: Option
    private let label: (Option) -> String

    public init(_ options: [Option], selection: Binding<Option>, label: @escaping (Option) -> String) {
        self.options = options; _selection = selection; self.label = label
    }

    public var body: some View {
        HStack(spacing: CaploMetrics.Spacing.xs) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: { Text(label(option)) }
                    .buttonStyle(ChipStyle(selected: option == selection))
                    .accessibilityAddTraits(option == selection ? .isSelected : [])
            }
        }
    }
}

/// chip 外观；也可单独用于按钮。
public struct ChipStyle: ButtonStyle {
    private let selected: Bool
    public init(selected: Bool) { self.selected = selected }

    public func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, selected: selected)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let selected: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        @FocusState private var focused: Bool

        var body: some View {
            configuration.label
                .font(CaploFont.caption)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: CaploMetrics.ControlHeight.small)
                .foregroundStyle(CaploColor.textPrimary)
                .background(
                    selected ? CaploColor.accentSoft : CaploColor.surfaceRaised.opacity(hovered ? 1 : 0.8),
                    in: RoundedRectangle(cornerRadius: CaploMetrics.Radius.control - 1))
                .overlay {
                    RoundedRectangle(cornerRadius: CaploMetrics.Radius.control - 1)
                        .strokeBorder(selected ? CaploColor.accent : focused ? CaploColor.accent.opacity(0.9) : CaploColor.separator,
                                      lineWidth: focused && !selected ? 2 : 1)
                }
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control - 1))
                .focused($focused)
                .focusEffectDisabled()
                .onHover { hovered = $0 }
        }
    }
}

import SwiftUI

/// 图标栏条目；`shortcut` 为 ⌘ 加数字键。
public struct RailItem: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let symbol: String
    public let shortcut: Character?

    public init(id: String, title: String, symbol: String, shortcut: Character? = nil) {
        self.id = id; self.title = title; self.symbol = symbol; self.shortcut = shortcut
    }
}

/// 编辑器左侧 48 点图标栏：直接坐在窗口底色上，选中项软底加 2 点左侧指示条，悬停显示名称，禁用项保留位置。
public struct IconRail: View {
    private let items: [RailItem]
    @Binding private var selection: String
    private let disabled: Set<String>

    public init(_ items: [RailItem], selection: Binding<String>, disabled: Set<String> = []) {
        self.items = items; _selection = selection; self.disabled = disabled
    }

    public var body: some View {
        VStack(spacing: CaploMetrics.Spacing.xs + 2) {
            ForEach(items) { item in
                let button = Button { selection = item.id } label: { Image(systemName: item.symbol) }
                    .buttonStyle(RailButtonStyle(selected: selection == item.id))
                    .disabled(disabled.contains(item.id))
                    .help(item.title)
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(selection == item.id ? .isSelected : [])
                if let key = item.shortcut {
                    button.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
                } else {
                    button
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, CaploMetrics.Spacing.s)
        .frame(width: CaploMetrics.railWidth)
        .frame(maxHeight: .infinity)
    }
}

private struct RailButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View { StyleBody(configuration: configuration, selected: selected) }

    private struct StyleBody: View {
        let configuration: Configuration
        let selected: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        @FocusState private var focused: Bool

        var body: some View {
            configuration.label
                .font(.system(size: CaploMetrics.Icon.rail - 3, weight: .medium))
                .frame(width: 32, height: 32)
                .foregroundStyle(selected ? CaploColor.textPrimary : CaploColor.textTertiary)
                .background(selected ? CaploColor.accentSoft : CaploColor.textPrimary.opacity(configuration.isPressed ? 0.1 : hovered ? 0.06 : 0),
                            in: RoundedRectangle(cornerRadius: CaploMetrics.Radius.control + 1))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(CaploColor.accent).frame(width: 2, height: 18).opacity(selected ? 1 : 0)
                }
                .overlay(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control + 1).strokeBorder(CaploColor.accent.opacity(focused ? 0.9 : 0), lineWidth: 2))
                .contentShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control + 1))
                .opacity(enabled ? 1 : 0.35)
                .focused($focused)
                .focusEffectDisabled()
                .onHover { hovered = $0 }
        }
    }
}

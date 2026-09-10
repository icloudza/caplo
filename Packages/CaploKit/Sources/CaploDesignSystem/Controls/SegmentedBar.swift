import SwiftUI

/// 自绘分段选择：整行圆角底板，选中段是更亮的圆角块并随选择平滑滑动，文字选中白色、其余次级色。
/// 用于“版式”这类三四个互斥文字选项；系统 `.segmented` 在深色面板里描边生硬、间隔线突兀，不用它。
public struct SegmentedBar<Option: Hashable>: View {
    private let options: [Option]
    @Binding private var selection: Option
    private let label: (Option) -> String
    @Namespace private var highlight
    @Environment(\.isEnabled) private var enabled

    public init(_ options: [Option], selection: Binding<Option>, label: @escaping (Option) -> String) {
        self.options = options; _selection = selection; self.label = label
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { withAnimation(.easeOut(duration: CaploMotion.hover)) { selection = option } } label: {
                    Text(label(option))
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? CaploColor.textPrimary : CaploColor.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity).frame(height: 26)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(CaploColor.surfaceOpaqueRaised)
                                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "segment", in: highlight)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(option))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(CaploColor.surfaceRaised.opacity(0.8)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(CaploColor.separator))
        .opacity(enabled ? 1 : 0.5)
    }
}

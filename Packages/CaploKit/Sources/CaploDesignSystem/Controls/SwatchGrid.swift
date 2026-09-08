import SwiftUI

/// 背景色板项：一个颜色为纯色，两个及以上为对角渐变。
public struct Swatch: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let colors: [Color]

    public init(id: String, name: String, colors: [Color]) {
        self.id = id; self.name = name; self.colors = colors
    }

    public var fill: LinearGradient {
        LinearGradient(colors: colors.count == 1 ? [colors[0], colors[0]] : colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// 色板网格，选中项用强调色外描边；每格保持正方形，列数由调用方决定。
public struct SwatchGrid: View {
    private let swatches: [Swatch]
    @Binding private var selection: String?
    private let columns: Int
    private let onSelect: (Swatch) -> Void

    public init(_ swatches: [Swatch], selection: Binding<String?>, columns: Int = 7, onSelect: @escaping (Swatch) -> Void = { _ in }) {
        self.swatches = swatches; _selection = selection; self.columns = columns; self.onSelect = onSelect
    }

    public var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: CaploMetrics.Spacing.xs + 1), count: columns), spacing: CaploMetrics.Spacing.xs + 1) {
            ForEach(swatches) { swatch in
                Button { selection = swatch.id; onSelect(swatch) } label: {
                    RoundedRectangle(cornerRadius: CaploMetrics.Radius.control)
                        .fill(swatch.fill)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control).strokeBorder(CaploColor.separator))
                        .overlay {
                            // 选中环画在色块外 2 点：外圆角 = 色块圆角 + 间距，环与色块同心，四角不会露出缝隙。
                            if selection == swatch.id {
                                RoundedRectangle(cornerRadius: CaploMetrics.Radius.control + 2, style: .continuous)
                                    .strokeBorder(CaploColor.accent, lineWidth: 1.5)
                                    .padding(-2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(selection == swatch.id ? .isSelected : [])
            }
        }
    }
}

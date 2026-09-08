import SwiftUI

/// 属性面板的标准参数行：标签左、数值右、可选"重置"，下方细滑块。
/// 拖动过程中通过 `onEditingChanged` 通知调用方，便于只在松开时提交一次历史。
public struct LabeledSlider: View {
    private let title: String
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let defaultValue: Double?
    private let format: (Double) -> String
    private let editing: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled

    public init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                defaultValue: Double? = nil,
                format: @escaping (Double) -> String = { String(format: "%.0f", $0) },
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title; _value = value; self.range = range
        self.defaultValue = defaultValue; self.format = format; editing = onEditingChanged
    }

    private var showsReset: Bool {
        guard let defaultValue else { return false }
        return abs(value - defaultValue) > 0.0001
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CaploMetrics.Spacing.xs) {
            HStack(spacing: CaploMetrics.Spacing.s) {
                Text(title).font(CaploFont.body).foregroundStyle(CaploColor.textPrimary)
                Spacer(minLength: 0)
                if showsReset, let defaultValue {
                    Button("重置") { editing(true); value = defaultValue; editing(false) }
                        .buttonStyle(.plain)
                        .font(CaploFont.caption)
                        .foregroundStyle(CaploColor.accent)
                        .accessibilityLabel("重置\(title)")
                }
                Text(format(value)).font(CaploFont.value).foregroundStyle(CaploColor.textSecondary)
                    .frame(minWidth: 32, alignment: .trailing)
            }
            StudioSlider(title, value: $value, in: range, onEditingChanged: editing)
        }
        .opacity(enabled ? 1 : 0.5)
    }
}

import SwiftUI
import AppKit

/// 胶囊滑条：整条就是一个圆角块，填充多少就是值多少，标题和数值都写在块里。
/// 给"多少"类的量用——不透明度、强度、音量、模糊程度这类 0–100% 的比例：
/// 看填充长短就知道大概，不需要卡尺那样的刻度；一行就是一个参数，比"标题行 + 卡尺行"省一半高度。
///
/// 交互：按下即把值定到指针处，拖动跟手（按住 ⌥ 精调，移动量只算十分之一）；
/// 靠近档位（`detents`）时吸附；双击恢复默认；获得焦点后方向键走 1%、⇧ 走 10%。
public struct FillSlider: View {
    private let title: String
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let defaultValue: Double?
    private let detents: [Double]
    private let format: (Double) -> String
    private let editing: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool
    @State private var drag: (anchorValue: Double, anchorX: CGFloat, fine: Bool)?
    @State private var hovered = false

    public init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                defaultValue: Double? = nil, detents: [Double] = [],
                format: @escaping (Double) -> String,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title; _value = value; self.range = range
        self.defaultValue = defaultValue; self.detents = detents.filter { range.contains($0) }
        self.format = format; editing = onEditingChanged
    }

    private var span: Double { max(0.000_001, range.upperBound - range.lowerBound) }
    private var fraction: Double { min(1, max(0, (value - range.lowerBound) / span)) }

    public var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(CaploColor.surfaceRaised.opacity(hovered || drag != nil ? 1 : 0.85))
                // 填充：软色块加一条亮边，亮边就是当前值的位置。
                Rectangle()
                    .fill(CaploColor.accentSoft)
                    .frame(width: width * fraction)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(CaploColor.accent.opacity(drag != nil ? 1 : 0.75)).frame(width: fraction > 0.002 ? 2 : 0)
                    }
                ForEach(detents, id: \.self) { detent in
                    let x = width * (detent - range.lowerBound) / span
                    Rectangle().fill(CaploColor.textPrimary.opacity(0.22))
                        .frame(width: CaploMetrics.hairline, height: 4)
                        .offset(x: x - 0.5, y: 9)
                }
                HStack(spacing: CaploMetrics.Spacing.s) {
                    Text(title).font(CaploFont.body).foregroundStyle(CaploColor.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(format(value)).font(CaploFont.value)
                        .foregroundStyle(drag != nil ? CaploColor.textPrimary : CaploColor.textSecondary)
                }
                .padding(.horizontal, 10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(focused ? CaploColor.accent : CaploColor.separator, lineWidth: focused ? 1.5 : CaploMetrics.hairline))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { event in
                        guard enabled else { return }
                        let fine = NSEvent.modifierFlags.contains(.option)
                        if drag == nil {
                            editing(true); focused = true
                            // 按下就把值定到指针处；精调从当前值起算，不跳。
                            let start = fine ? value : snapped(range.lowerBound + Double(event.startLocation.x / width) * span)
                            drag = (start, event.startLocation.x, fine)
                        }
                        guard var state = drag else { return }
                        if state.fine != fine {
                            // 中途按下 / 松开 ⌥：以当前值和当前位置重新起算，避免跳变。
                            state = (value, event.location.x, fine); drag = state
                        }
                        let scale = fine ? 0.1 : 1
                        let raw = state.anchorValue + Double((event.location.x - state.anchorX) / width) * span * scale
                        value = fine ? clamped(raw) : snapped(raw)
                    }
                    .onEnded { _ in
                        guard drag != nil else { return }
                        drag = nil; editing(false)
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { if let defaultValue { commit(defaultValue) } })
        }
        .frame(height: 28)
        .onHover { hovered = $0 }
        .opacity(enabled ? 1 : 0.45)
        .focusable(enabled).focused($focused).focusEffectDisabled()
        .onMoveCommand { direction in
            guard enabled else { return }
            let step = span * (NSEvent.modifierFlags.contains(.shift) ? 0.1 : 0.01)
            switch direction {
            case .left, .down: commit(value - step)
            case .right, .up: commit(value + step)
            default: break
            }
        }
        .hoverTip(defaultValue == nil ? "拖动调整，按住 ⌥ 精调" : "拖动调整，按住 ⌥ 精调，双击恢复默认")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: commit(value + span * 0.05)
            case .decrement: commit(value - span * 0.05)
            @unknown default: break
            }
        }
    }

    private func commit(_ target: Double) {
        guard enabled else { return }
        let next = clamped(target)
        guard abs(next - value) > 1e-9 else { return }
        editing(true); value = next; editing(false)
    }
    private func clamped(_ raw: Double) -> Double { min(range.upperBound, max(range.lowerBound, raw)) }
    /// 吸附：离档位不到全程的 2% 就落到档位上。
    private func snapped(_ raw: Double) -> Double {
        let value = clamped(raw)
        guard let nearest = detents.min(by: { abs($0 - value) < abs($1 - value) }), abs(nearest - value) < span * 0.02 else { return value }
        return nearest
    }
}

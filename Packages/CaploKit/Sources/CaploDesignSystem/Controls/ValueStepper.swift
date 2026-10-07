import SwiftUI
import AppKit

/// 数值步进器：标题在左，右侧一组「− 数值 +」。给"秒"这类范围小、要精确到一步的量用——
/// 推近 / 拉远时长、淡入淡出、入场出场时长……用卡尺调 0.05 秒要对准细刻度，步进器点一下就是一步。
///
/// 交互：点 ± 走一步、按住连续走；在数值上左右拖动快速调（每 6 点一步，按住 ⌥ 每 18 点一步）；
/// 双击数值或点"重置"回默认值；获得焦点后方向键走一步、⇧ 走十步。
/// 拖动与重置都包在 `onEditingChanged(true / false)` 之间，调用方据此只记一步撤销。
public struct ValueStepper: View {
    private let title: String
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let defaultValue: Double?
    private let format: (Double) -> String
    private let editing: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool
    @State private var scrub: (origin: Double, active: Bool)?
    @State private var hoveredValue = false

    public init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
                defaultValue: Double? = nil,
                format: @escaping (Double) -> String,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title; _value = value; self.range = range
        self.step = step > 0 ? step : max(0.0001, (range.upperBound - range.lowerBound) / 100)
        self.defaultValue = defaultValue; self.format = format; editing = onEditingChanged
    }

    private var showsReset: Bool { defaultValue.map { abs(value - $0) > step / 2 } ?? false }

    public var body: some View {
        HStack(spacing: CaploMetrics.Spacing.s) {
            Text(title).font(CaploFont.body).foregroundStyle(CaploColor.textPrimary).lineLimit(1)
            Spacer(minLength: 0)
            if showsReset, let defaultValue {
                Button("重置") { commit(defaultValue) }
                    .buttonStyle(.plain).font(CaploFont.caption).foregroundStyle(CaploColor.accent)
                    .accessibilityLabel("重置\(title)")
            }
            HStack(spacing: 0) {
                stepButton(symbol: "minus", delta: -1).disabled(value <= range.lowerBound + step / 2)
                Rectangle().fill(CaploColor.separator).frame(width: CaploMetrics.hairline, height: 14)
                valueField
                Rectangle().fill(CaploColor.separator).frame(width: CaploMetrics.hairline, height: 14)
                stepButton(symbol: "plus", delta: 1).disabled(value >= range.upperBound - step / 2)
            }
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(CaploColor.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(focused ? CaploColor.accent : CaploColor.separator, lineWidth: focused ? 1.5 : CaploMetrics.hairline))
        }
        .frame(minHeight: 28)
        .opacity(enabled ? 1 : 0.5)
        .focusable(enabled).focused($focused).focusEffectDisabled()
        .onMoveCommand { direction in
            guard enabled else { return }
            let steps: Double = NSEvent.modifierFlags.contains(.shift) ? 10 : 1
            switch direction {
            case .left, .down: commit(value - step * steps)
            case .right, .up: commit(value + step * steps)
            default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: commit(value + step)
            case .decrement: commit(value - step)
            @unknown default: break
            }
        }
    }

    private var valueField: some View {
        Text(format(value))
            .font(CaploFont.value)
            .foregroundStyle(scrub?.active == true ? CaploColor.textPrimary : CaploColor.textPrimary.opacity(0.92))
            .frame(minWidth: 60).padding(.horizontal, 4)
            .frame(maxHeight: .infinity)
            .background(hoveredValue || scrub?.active == true ? CaploColor.textPrimary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
            .onHover { inside in
                // 数值上可以左右拖：光标换成左右箭头提示，离开时还原（压栈 / 出栈要成对）。
                guard enabled, inside != hoveredValue else { return }
                hoveredValue = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hoveredValue { NSCursor.pop(); hoveredValue = false } }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        guard enabled else { return }
                        if scrub == nil { scrub = (value, true); editing(true); focused = true }
                        let pixelsPerStep: Double = NSEvent.modifierFlags.contains(.option) ? 18 : 6
                        let steps = (drag.translation.width / pixelsPerStep).rounded()
                        value = clamped(quantized((scrub?.origin ?? value) + steps * step))
                    }
                    .onEnded { _ in
                        guard scrub != nil else { return }
                        scrub = nil; editing(false)
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { if let defaultValue { commit(defaultValue) } })
            .hoverTip(String(localized: "左右拖动 · 双击复位"))
    }

    private func stepButton(symbol: String, delta: Double) -> some View {
        Button { commit(value + delta * step) } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CaploColor.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(StepperButtonStyle())
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(delta < 0 ? "减少\(title)" : "增加\(title)")
    }

    /// 一次性改动：点按钮、方向键、重置。前后各通知一次，调用方记成一步撤销。
    private func commit(_ target: Double) {
        guard enabled else { return }
        let next = clamped(quantized(target))
        guard abs(next - value) > 1e-9 else { return }
        editing(true); value = next; editing(false)
    }
    /// 落到步长网格上（以范围下限为起点），避免 0.6 + 0.05 × n 攒出 0.6500000001 这类尾巴。
    private func quantized(_ raw: Double) -> Double {
        let steps = ((raw - range.lowerBound) / step).rounded()
        return range.lowerBound + steps * step
    }
    private func clamped(_ raw: Double) -> Double { min(range.upperBound, max(range.lowerBound, raw)) }
}

/// ± 按钮：按下时底色提亮，不画系统按钮外观。
private struct StepperButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(enabled ? 1 : 0.35)
            .background(configuration.isPressed ? CaploColor.textPrimary.opacity(0.1) : .clear)
    }
}

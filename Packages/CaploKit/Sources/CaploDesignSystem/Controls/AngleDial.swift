import SwiftUI
import AppKit

/// 角度旋钮：圆盘上一根指针，指哪就是多少度——角度本来就是"转"出来的，比在直线卡尺上找 -180…180 直观。
/// 约定与光标渲染一致：0° 朝上，顺时针为正，范围 -180…180。
///
/// 交互：在圆盘上按下拖动，指针跟着指针方向转（以圆心为轴）；靠近 0°、±90°、180° 时吸附，按住 ⇧ 每 15° 一档；
/// 右侧三个快捷档直接设到 -90° / 0° / 90°；双击圆盘恢复默认；获得焦点后方向键走 1°、⇧ 走 15°。
public struct AngleDial: View {
    private let title: String
    @Binding private var value: Double
    private let defaultValue: Double
    private let editing: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool
    @State private var dragging = false
    private let diameter: CGFloat = 52
    nonisolated private static let detents: [Double] = [-180, -90, 0, 90, 180]

    public init(_ title: String, value: Binding<Double>, defaultValue: Double = 0, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title; _value = value; self.defaultValue = defaultValue; editing = onEditingChanged
    }

    public var body: some View {
        HStack(spacing: CaploMetrics.Spacing.m) {
            dial
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: CaploMetrics.Spacing.s) {
                    Text(title).font(CaploFont.body).foregroundStyle(CaploColor.textPrimary)
                    Spacer(minLength: 0)
                    if abs(value - defaultValue) > 0.5 {
                        Button("重置") { commit(defaultValue) }
                            .buttonStyle(.plain).font(CaploFont.caption).foregroundStyle(CaploColor.accent)
                            .accessibilityLabel("重置\(title)")
                    }
                    Text(String(format: "%.0f°", value)).font(CaploFont.value).foregroundStyle(CaploColor.textSecondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }
                HStack(spacing: 4) {
                    ForEach([-90.0, 0, 90], id: \.self) { preset in
                        Button { commit(preset) } label: {
                            Text(String(format: "%.0f°", preset)).font(CaploFont.caption)
                                .foregroundStyle(abs(value - preset) < 0.5 ? CaploColor.textPrimary : CaploColor.textSecondary)
                                .frame(maxWidth: .infinity).frame(height: 22)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(abs(value - preset) < 0.5 ? CaploColor.accentSoft : CaploColor.surfaceRaised))
                                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(title)设为 \(Int(preset)) 度")
                    }
                }
            }
        }
        .opacity(enabled ? 1 : 0.5)
    }

    private var dial: some View {
        ZStack {
            Circle().fill(CaploColor.surfaceRaised)
            Circle().strokeBorder(focused ? CaploColor.accent : CaploColor.separator, lineWidth: focused ? 1.5 : CaploMetrics.hairline)
            // 刻度：每 45° 一根，四个正方向更长。
            ForEach(0..<8, id: \.self) { index in
                let major = index % 2 == 0
                Capsule().fill(CaploColor.textPrimary.opacity(major ? 0.35 : 0.18))
                    .frame(width: 1.5, height: major ? 5 : 3)
                    .offset(y: -(diameter / 2 - (major ? 5.5 : 4.5)))
                    .rotationEffect(.degrees(Double(index) * 45))
            }
            // 指针：从圆心到边缘的一根亮线，末端一个圆点。
            Capsule().fill(CaploColor.accent)
                .frame(width: 2, height: diameter / 2 - 9)
                .offset(y: -(diameter / 2 - 9) / 2)
                .rotationEffect(.degrees(value))
            Circle().fill(CaploColor.accent).frame(width: 6, height: 6)
                .offset(y: -(diameter / 2 - 9))
                .rotationEffect(.degrees(value))
            Circle().fill(CaploColor.textPrimary.opacity(0.85)).frame(width: 4, height: 4)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { event in
                    guard enabled else { return }
                    if !dragging { dragging = true; focused = true; editing(true) }
                    value = Self.angle(at: event.location, center: CGPoint(x: diameter / 2, y: diameter / 2),
                                       quarter: NSEvent.modifierFlags.contains(.shift))
                }
                .onEnded { _ in
                    guard dragging else { return }
                    dragging = false; editing(false)
                }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { commit(defaultValue) })
        .focusable(enabled).focused($focused).focusEffectDisabled()
        .onMoveCommand { direction in
            guard enabled else { return }
            let step: Double = NSEvent.modifierFlags.contains(.shift) ? 15 : 1
            switch direction {
            case .left, .down: commit(value - step)
            case .right, .up: commit(value + step)
            default: break
            }
        }
        .hoverTip(String(localized: "⇧ 15° 一档 · 双击复位"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Int(value.rounded())) 度")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: commit(value + 15)
            case .decrement: commit(value - 15)
            @unknown default: break
            }
        }
    }

    /// 指针方向 → 角度：0° 朝上、顺时针为正（视图坐标 y 向下）。靠近正方向 4° 内吸附；`quarter` 时按 15° 取整。
    /// 纯换算，不碰视图状态：标成不隔离，任何线程都能调用（测试就在后台线程调用）。
    nonisolated static func angle(at point: CGPoint, center: CGPoint, quarter: Bool) -> Double {
        let dx = point.x - center.x, dy = point.y - center.y
        guard hypot(dx, dy) > 0.5 else { return 0 }
        var degrees = atan2(dx, -dy) * 180 / .pi
        if quarter { degrees = (degrees / 15).rounded() * 15 }
        else if let detent = detents.min(by: { abs($0 - degrees) < abs($1 - degrees) }), abs(detent - degrees) < 4 { degrees = detent }
        return min(180, max(-180, degrees))
    }

    private func commit(_ target: Double) {
        guard enabled else { return }
        let next = min(180, max(-180, target.rounded()))
        guard abs(next - value) > 1e-9 else { return }
        editing(true); value = next; editing(false)
    }
}

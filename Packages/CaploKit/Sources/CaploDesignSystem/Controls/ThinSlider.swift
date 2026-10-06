import SwiftUI

/// 细滑条：前面一个说明用途的小图标，后面一根 2 点细轨加一颗小圆钮，参照 Logic 工具栏里的缩放滑条。
/// 用在工具栏这种寸土寸金、只需"往大一点 / 往小一点"拨的地方；需要读数、刻度的参数仍用卡尺或胶囊滑条。
///
/// 交互：按住轨道任意处圆钮跳过去并跟手拖；双击恢复（`onReset`，没给就不响应）；获得焦点后方向键每次走 1/20。
/// 拖动是连续的，不吸附档位。
public struct ThinSlider: View {
    private let title: String
    private let systemImage: String
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let reset: (() -> Void)?
    @State private var dragging = false
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    private let knob: CGFloat = 11
    private let track: CGFloat = 2

    public init(_ title: String, systemImage: String, value: Binding<Double>, in range: ClosedRange<Double>, onReset: (() -> Void)? = nil) {
        self.title = title; self.systemImage = systemImage; _value = value; self.range = range; reset = onReset
    }

    private var span: Double { max(0.0001, range.upperBound - range.lowerBound) }
    private var fraction: Double { min(1, max(0, (value - range.lowerBound) / span)) }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CaploColor.textSecondary)
                .accessibilityHidden(true)
            GeometryReader { proxy in
                let travel = max(1, proxy.size.width - knob)
                ZStack(alignment: .leading) {
                    Capsule().fill(CaploColor.textPrimary.opacity(0.16)).frame(height: track)
                        .padding(.horizontal, knob / 2)
                    Circle().fill(Color(white: 0.96))
                        .overlay(Circle().strokeBorder(focused ? CaploColor.accent : .black.opacity(0.22), lineWidth: focused ? 1.5 : 0.5))
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .frame(width: knob, height: knob)
                        .scaleEffect(dragging ? 1.12 : 1)
                        .offset(x: travel * fraction)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    guard enabled else { return }
                    if !dragging { dragging = true; focused = true }
                    value = range.lowerBound + min(1, max(0, (event.location.x - knob / 2) / travel)) * span
                }.onEnded { _ in dragging = false })
                .simultaneousGesture(TapGesture(count: 2).onEnded { if enabled { reset?() } })
            }
            .frame(height: CaploMetrics.Slider.hitHeight)
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .opacity(enabled ? 1 : 0.4)
        .focusable(enabled).focused($focused).focusEffectDisabled()
        .onMoveCommand { direction in
            guard enabled else { return }
            switch direction {
            case .left, .down: value = max(range.lowerBound, value - span / 20)
            case .right, .up: value = min(range.upperBound, value + span / 20)
            default: break
            }
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: range) { Text(title) }
        }
    }
}

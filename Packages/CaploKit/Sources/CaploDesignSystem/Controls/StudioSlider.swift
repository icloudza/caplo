import SwiftUI

/// 固定轨道和手柄外观（3 点轨道、14 点手柄、22 点命中高度），防止系统升级改变参数面板密度；
/// 保留原生滑块的辅助功能语义。
public struct StudioSlider: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let title: String
    private let editing: (Bool) -> Void
    @State private var dragging = false
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled

    public init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title; _value = value; self.range = range; editing = onEditingChanged
    }

    private var fraction: Double { min(1, max(0, (value - range.lowerBound) / max(0.0001, range.upperBound - range.lowerBound))) }
    private var thumb: CGFloat { CaploMetrics.Slider.thumb }
    private var track: CGFloat { CaploMetrics.Slider.track }

    public var body: some View {
        GeometryReader { proxy in
            let travel = max(1, proxy.size.width - thumb)
            ZStack(alignment: .leading) {
                Capsule().fill(CaploColor.textPrimary.opacity(0.12)).frame(height: track)
                Capsule().fill(CaploColor.textPrimary.opacity(0.75)).frame(width: thumb / 2 + travel * fraction, height: track)
                Circle().fill(.white).frame(width: thumb, height: thumb)
                    .overlay(Circle().strokeBorder(focused ? CaploColor.accent : .black.opacity(0.18), lineWidth: focused ? 2 : 1))
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1).offset(x: travel * fraction)
            }.frame(height: CaploMetrics.Slider.hitHeight).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    guard enabled else { return }
                    if !dragging { editing(true); dragging = true; focused = true }
                    value = range.lowerBound + min(1, max(0, (event.location.x - thumb / 2) / travel)) * (range.upperBound - range.lowerBound)
                }.onEnded { _ in if dragging { dragging = false; editing(false) } })
        }.frame(height: CaploMetrics.Slider.hitHeight).opacity(enabled ? 1 : 0.4)
            .focusable(enabled).focused($focused).focusEffectDisabled()
            .onMoveCommand { direction in
                guard enabled else { return }
                let step = (range.upperBound - range.lowerBound) / 100
                editing(true)
                if direction == .left || direction == .down { value = max(range.lowerBound, value - step) }
                if direction == .right || direction == .up { value = min(range.upperBound, value + step) }
                editing(false)
            }
            .accessibilityRepresentation {
                Slider(value: Binding(get: { value }, set: { editing(true); value = $0; editing(false) }), in: range) { Text(title) }
            }
    }
}

import SwiftUI

/// 34 点圆形 REC 按钮（外圈 3 点，视觉 40 点）；悬停轻微放大，按下缩小，禁用降低透明度。
public struct RecordButton: View {
    private let title: String
    private let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var pressed = false
    @FocusState private var focused: Bool

    public init(title: String = "REC", action: @escaping () -> Void) { self.title = title; self.action = action }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(CaploColor.recordFill, in: Circle())
                .overlay(Circle().strokeBorder(CaploColor.record.opacity(hovered ? 0.35 : 0.18), lineWidth: 3).padding(-3))
                .overlay(Circle().strokeBorder(CaploColor.accent.opacity(focused ? 0.9 : 0), lineWidth: 2).padding(-6))
                .scaleEffect(reduceMotion ? 1 : pressed ? 0.94 : hovered ? 1.05 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in pressed = true }.onEnded { _ in pressed = false })
        .animation(CaploMotion.animation(CaploMotion.hover, reduceMotion: reduceMotion), value: hovered)
        .animation(CaploMotion.animation(CaploMotion.press, reduceMotion: reduceMotion), value: pressed)
        .accessibilityLabel("开始录制")
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CaploDesignSystem
import EditingCore
import RenderKit

struct LayoutInspector: View {
    @Binding var layout: CanvasLayout

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("画布样式").font(.system(size: 14, weight: .semibold))
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("画面比例")
                    HStack(spacing: 5) {
                        ForEach(CanvasRatio.allCases, id: \.self) { ratio in
                            ChoicePill(ratio.rawValue, selected: layout.ratio == ratio) { layout.ratio = ratio }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("背景")
                    BackgroundSwatches(options: CanvasBackground.gradients, selected: layout.background) { layout.background = $0 }
                }
                StudioDivider()
                valueSlider("留白", value: $layout.padding, range: 0...120)
                valueSlider("圆角", value: $layout.cornerRadius, range: 0...40)
                Toggle(isOn: $layout.shadow) {
                    SettingLabel("阴影", systemImage: "square.3.layers.3d")
                }
                .toggleStyle(CaploToggleStyle())
                StudioDivider()
                Button("重置样式") { layout = CanvasLayout() }
                    .buttonStyle(CaploButtonStyle())
                Text("样式修改仅用于当前预览，关闭窗口后不会保存。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
    }

    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue))").monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            StudioSlider(title, value: value, in: range)
                .tint(CaploStyle.accent)
        }
    }
}

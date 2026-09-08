import SwiftUI
import CaploDesignSystem
import EditingCore

/// 裁剪：按比例居中取框或用滑块自由调整；聚焦与光标坐标随裁切自动换算。
struct CropPanel: View {
    let model: VideoEditorModel
    private enum Preset: String, CaseIterable { case free = "自由", wide = "16:9", standard = "4:3", square = "1:1", tall = "9:16"
        var aspect: Double? {
            switch self { case .free: nil; case .wide: 16.0 / 9; case .standard: 4.0 / 3; case .square: 1; case .tall: 9.0 / 16 }
        }
    }

    private var crop: CropRect { model.edit.layout.crop ?? .full }
    private var sourceAspect: Double {
        if let size = model.entry.document.capture?.pixelSize, size.width > 0, size.height > 0 { return size.width / size.height }
        return 16.0 / 9
    }
    private var activePreset: Preset {
        let current = crop
        for preset in Preset.allCases where preset.aspect != nil {
            let candidate = CropRect.centered(aspect: preset.aspect!, sourceAspect: sourceAspect)
            if abs(candidate.x - current.x) < 0.002, abs(candidate.y - current.y) < 0.002, abs(candidate.width - current.width) < 0.002, abs(candidate.height - current.height) < 0.002 { return preset }
        }
        return .free
    }

    var body: some View {
        PanelNote("裁掉录屏画面的边缘。裁切后聚焦与点击效果仍对准原位置，导出与预览一致。")
        PanelSection("比例") {
            ChipGroup(Preset.allCases, selection: Binding(get: { activePreset }, set: { preset in
                model.commit { edit in
                    if let aspect = preset.aspect { edit.layout.crop = CropRect.centered(aspect: aspect, sourceAspect: sourceAspect) }
                    else if edit.layout.crop == nil { edit.layout.crop = .full }
                }
            })) { $0.rawValue }
        }
        PanelSection("范围") {
            EditorSlider(model: model, title: "左边距", value: binding(\.x, maximum: { 1 - $0.width }), range: 0...(1 - CropRect.minimumSide), suffix: "%", percentage: true, defaultValue: 0)
            EditorSlider(model: model, title: "上边距", value: binding(\.y, maximum: { 1 - $0.height }), range: 0...(1 - CropRect.minimumSide), suffix: "%", percentage: true, defaultValue: 0)
            EditorSlider(model: model, title: "宽度", value: binding(\.width, maximum: { 1 - $0.x }), range: CropRect.minimumSide...1, suffix: "%", percentage: true, defaultValue: 1)
            EditorSlider(model: model, title: "高度", value: binding(\.height, maximum: { 1 - $0.y }), range: CropRect.minimumSide...1, suffix: "%", percentage: true, defaultValue: 1)
        }
        Button("取消裁剪") { model.commit { $0.layout.crop = nil } }
            .buttonStyle(StudioButtonStyle(.secondary)).disabled(model.edit.layout.effectiveCrop == nil)
    }

    private func binding(_ key: WritableKeyPath<CropRect, Double>, maximum: @escaping (CropRect) -> Double) -> Binding<Double> {
        Binding(get: { crop[keyPath: key] }, set: { value in
            var next = model.edit.layout.crop ?? .full
            next[keyPath: key] = min(max(0, value), maximum(next))
            model.edit.layout.crop = next
        })
    }
}

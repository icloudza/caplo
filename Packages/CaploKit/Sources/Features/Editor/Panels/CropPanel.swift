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
        var title: String { self == .free ? String(localized: "自由") : rawValue }
    }

    private var crop: CropRect { model.edit.layout.crop ?? .full }
    private var sourceAspect: Double { model.sourceAspect }
    private var activePreset: Preset {
        let current = crop
        for preset in Preset.allCases where preset.aspect != nil {
            let candidate = CropRect.centered(aspect: preset.aspect!, sourceAspect: sourceAspect)
            if abs(candidate.x - current.x) < 0.002, abs(candidate.y - current.y) < 0.002, abs(candidate.width - current.width) < 0.002, abs(candidate.height - current.height) < 0.002 { return preset }
        }
        return .free
    }

    var body: some View {
        PanelNote(String(localized: "裁掉录屏画面的边缘。裁切后聚焦与点击效果仍对准原位置，导出与预览一致。"))
        PanelSection(String(localized: "比例")) {
            ChipGroup(Preset.allCases, selection: Binding(get: { activePreset }, set: { preset in
                model.commit { edit in
                    if let aspect = preset.aspect { edit.layout.crop = CropRect.centered(aspect: aspect, sourceAspect: sourceAspect) }
                    else if edit.layout.crop == nil { edit.layout.crop = .full }
                }
            })) { $0.title }
        }
        PanelSection(String(localized: "范围")) {
            // 在录制画面比例的底板上直接拖裁剪框：移动框、拉四角，比四条边距滑块直观。
            EditorRegion(model: model, title: String(localized: "保留区域"), shape: .box(minimumSide: CropRect.minimumSide), aspect: sourceAspect,
                         region: cropRegion, defaultRegion: CGRect(x: 0, y: 0, width: 1, height: 1), readout: EditorRegion.sizeReadout)
        }
        Button("取消裁剪") { model.commit { $0.layout.crop = nil } }
            .buttonStyle(StudioButtonStyle(.secondary)).disabled(model.edit.layout.effectiveCrop == nil)
    }

    private var cropRegion: Binding<CGRect> {
        Binding(get: { CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height) }, set: { rect in
            let width = min(1, max(CropRect.minimumSide, rect.width)), height = min(1, max(CropRect.minimumSide, rect.height))
            model.edit.layout.crop = CropRect(x: min(1 - width, max(0, rect.minX)), y: min(1 - height, max(0, rect.minY)), width: width, height: height)
        })
    }
}

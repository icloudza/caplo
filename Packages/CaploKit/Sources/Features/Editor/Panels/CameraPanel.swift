import SwiftUI
import CaploDesignSystem
import EditingCore

/// 摄像头画中画：显示、形状、停靠、位置、大小、镜像与阴影。
struct CameraPanel: View {
    let model: VideoEditorModel
    private enum Shape: String, CaseIterable { case circle = "圆形", rounded = "圆角矩形" }
    private enum Dock: String, CaseIterable { case topLeading = "左上", topTrailing = "右上", bottomLeading = "左下", bottomTrailing = "右下"
        var point: (Double, Double) {
            switch self { case .topLeading: (0, 0); case .topTrailing: (1, 0); case .bottomLeading: (0, 1); case .bottomTrailing: (1, 1) }
        }
    }

    var body: some View {
        if model.entry.document.segments.contains(where: { $0.files[.camera] != nil }) {
            Toggle(isOn: Binding(get: { model.edit.camera?.enabled == true }, set: { value in
                model.commit { edit in
                    if edit.camera == nil { edit.camera = CameraLayout() }
                    edit.camera?.enabled = value
                }
            })) { SettingLabel("显示人像", systemImage: "person.crop.circle") }.toggleStyle(StudioToggleStyle())
            Group {
                PanelSection("形状") {
                    ChipGroup(Shape.allCases, selection: Binding(get: { model.edit.camera?.shape == .roundedRectangle ? Shape.rounded : .circle }, set: { shape in
                        model.commit { $0.camera?.shape = shape == .circle ? .circle : .roundedRectangle }
                    })) { $0.rawValue }
                }
                PanelSection("停靠位置") {
                    ChipGroup(Dock.allCases, selection: Binding(get: {
                        Dock.allCases.first { $0.point.0 == model.edit.camera?.x && $0.point.1 == model.edit.camera?.y } ?? .bottomTrailing
                    }, set: { dock in model.commit { $0.camera?.x = dock.point.0; $0.camera?.y = dock.point.1 } })) { $0.rawValue }
                }
                PanelSection("布局") {
                    EditorSlider(model: model, title: "大小", value: binding(\.size), range: 0.12...0.45, suffix: "%", percentage: true)
                    EditorSlider(model: model, title: "水平位置", value: binding(\.x), range: 0...1, suffix: "%", percentage: true, detents: [0, 0.5, 1])
                    EditorSlider(model: model, title: "垂直位置", value: binding(\.y), range: 0...1, suffix: "%", percentage: true, detents: [0, 0.5, 1])
                    Toggle(isOn: Binding(get: { model.edit.camera?.mirrored == true }, set: { value in model.commit { $0.camera?.mirrored = value } })) {
                        SettingLabel("镜像", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }.toggleStyle(StudioToggleStyle())
                    Toggle(isOn: Binding(get: { model.edit.camera?.shadow == true }, set: { value in model.commit { $0.camera?.shadow = value } })) {
                        SettingLabel("阴影", systemImage: "square.3.layers.3d")
                    }.toggleStyle(StudioToggleStyle())
                }
            }.disabled(model.edit.camera?.enabled != true)
            Button("重置人像布局") { model.commit { $0.camera = CameraLayout() } }.buttonStyle(StudioButtonStyle(.secondary))
        } else {
            PanelNote("此录制没有摄像头素材。下次录制前可在录制条开启摄像头。")
        }
    }

    private func binding(_ key: WritableKeyPath<CameraLayout, Double>) -> Binding<Double> {
        Binding(get: { (model.edit.camera ?? CameraLayout())[keyPath: key] }, set: { value in model.edit.camera?[keyPath: key] = value })
    }
}

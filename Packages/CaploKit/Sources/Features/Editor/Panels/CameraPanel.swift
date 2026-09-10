import SwiftUI
import CaploDesignSystem
import EditingCore

/// 摄像头画中画：显示、布局缩略图（叠放四角 / 分屏两侧）、大小与位置、镜像与阴影。
struct CameraPanel: View {
    let model: VideoEditorModel
    @State private var customizing = false
    /// 打开对话框前先把两张原帧与背景图取好，对话框一出现就是完整画面，不闪占位。
    @State private var customStills: CustomLayoutStills?
    @State private var loadingStills = false

    /// 布局预设：与 FocuSee 一样用缩略图挑：圆形右下、左右分屏、小卡片贴左压在录屏上、圆角矩形右上、人像全屏配录屏小窗、大卡片贴右垫在录屏后。
    struct Preset: Identifiable, Equatable {
        let id: String
        let name: String
        let mode: CameraLayout.Mode
        let shape: CameraLayout.Shape
        let x: Double
        let y: Double
        let sideHeight: Double
        let cornerRadius: Double

        static let all: [Preset] = [
            Preset(id: "circle-trailing-bottom", name: "圆形 · 右下", mode: .overlay, shape: .circle, x: 1, y: 1, sideHeight: 0.45, cornerRadius: 0.5),
            Preset(id: "split-leading", name: "分屏 · 人像在左", mode: .splitLeading, shape: .roundedRectangle, x: 0, y: 1, sideHeight: 0.45, cornerRadius: 0.14),
            Preset(id: "side-leading", name: "侧边 · 人像在左", mode: .sideLeading, shape: .roundedRectangle, x: 0, y: 0, sideHeight: 0.45, cornerRadius: 0.14),
            Preset(id: "rounded-trailing-top", name: "圆角矩形 · 右上", mode: .overlay, shape: .roundedRectangle, x: 1, y: 0, sideHeight: 0.45, cornerRadius: 0.14),
            Preset(id: "camera-full", name: "人像全屏 · 录屏小窗", mode: .cameraFull, shape: .roundedRectangle, x: 1, y: 1, sideHeight: 0.45, cornerRadius: 0.14),
            Preset(id: "behind-trailing", name: "人像在后 · 右侧", mode: .behindTrailing, shape: .roundedRectangle, x: 1, y: 0, sideHeight: 0.9, cornerRadius: 0.14),
        ]

        /// 当前布局对应哪个预设：预设与它的水平翻转算同一格（翻转后格子仍选中、缩略图镜像显示）；
        /// 卡片与全屏布局只看模式，叠放要形状与角都一致；拖过位置就没有预设被选中。
        static func matching(_ layout: CameraLayout?) -> Preset? {
            guard let layout else { return nil }
            return all.first { $0.matches(layout) || $0.matchesFlipped(layout) }
        }

        func matches(_ layout: CameraLayout) -> Bool {
            mode == layout.mode && (mode != .overlay
                || (shape == layout.shape && x == layout.x && y == layout.y && abs(layout.aspect - 4.0 / 3.0) < 0.001 && !layout.belowScreen))
        }
        /// 当前布局是这一格水平翻转后的样子。
        func matchesFlipped(_ layout: CameraLayout) -> Bool {
            guard mode != .cameraFull else { return false }
            return matches(layout.flippedHorizontally())
        }

        /// 套用预设：人像布局按预设写；录屏摆位随之归位——人像全屏时录屏缩成右下角小窗，其余布局录屏回到留白内铺满。
        func apply(to edit: inout VideoEdit) {
            guard edit.camera != nil else { return }
            edit.camera?.mode = mode; edit.camera?.shape = shape; edit.camera?.x = x; edit.camera?.y = y
            edit.camera?.sideHeight = sideHeight; edit.camera?.cornerRadius = cornerRadius
            edit.camera?.aspect = 4.0 / 3.0; edit.camera?.belowScreen = false
            if mode == .cameraFull { edit.layout.screenScale = 0.32; edit.layout.screenOffsetX = 1; edit.layout.screenOffsetY = 1 }
            else { edit.layout.screenScale = 1; edit.layout.screenOffsetX = 0; edit.layout.screenOffsetY = 0 }
        }

        func apply(to layout: inout CameraLayout) {
            var edit = VideoEdit(duration: 1); edit.camera = layout
            apply(to: &edit)
            layout = edit.camera ?? layout
        }
    }

    var body: some View {
        if model.hasCameraMedia {
            Toggle(isOn: Binding(get: { model.edit.camera?.enabled == true }, set: { value in
                model.commit { edit in
                    if edit.camera == nil { edit.camera = CameraLayout() }
                    edit.camera?.enabled = value
                }
            })) { SettingLabel("显示人像", systemImage: "person.crop.circle") }.toggleStyle(StudioToggleStyle())
            Group {
                PanelSection("摄像头布局") {
                    let current = Preset.matching(model.edit.camera)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: CaploMetrics.Spacing.xs), count: 3), spacing: CaploMetrics.Spacing.xs) {
                        ForEach(Preset.all) { preset in
                            Button { model.commit { edit in preset.apply(to: &edit) } } label: {
                                // 翻转后的布局仍算这一格，缩略图跟着镜像。
                                LayoutThumbnail(preset: preset)
                                    .scaleEffect(x: model.edit.camera.map { preset.matchesFlipped($0) && !preset.matches($0) } == true ? -1 : 1)
                            }
                            .buttonStyle(LayoutTileStyle(selected: current == preset))
                            .help(preset.name)
                            .accessibilityLabel(preset.name)
                            .accessibilityAddTraits(current == preset ? .isSelected : [])
                        }
                    }
                }
                PanelSection("调整") {
                    let layout = model.edit.camera ?? CameraLayout()
                    HStack(spacing: CaploMetrics.Spacing.s) {
                        // 翻转的是布局（人像换到对侧、自定义摆过的录屏也换到对侧），不是画面镜像。
                        Button { model.commit { CameraPanel.flip(&$0) } } label: { Label("水平翻转", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity) }
                            .buttonStyle(StudioButtonStyle(.secondary))
                        Button {
                            guard !loadingStills else { return }
                            loadingStills = true
                            Task { customStills = await CustomLayoutStills.load(model: model); loadingStills = false; customizing = true }
                        } label: { Label("自定义布局", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                            .buttonStyle(StudioButtonStyle(.secondary))
                            .disabled(loadingStills)
                    }
                    if layout.isSplit {
                        // 分屏的尺寸完全由画布决定，没有可调的大小。
                    } else if layout.isCameraFull {
                        EditorSlider(model: model, title: "录屏大小", value: Binding(get: { model.edit.layout.screenScale }, set: { model.edit.layout.screenScale = $0 }),
                                     range: 0.2...0.6, suffix: "%", percentage: true, detents: [0.32])
                    } else if layout.isBehind {
                        EditorSlider(model: model, title: "人像高度", value: binding(\.sideHeight), range: 0.6...1, suffix: "%", percentage: true, detents: [0.9])
                    } else if layout.isSide {
                        EditorSlider(model: model, title: "人像高度", value: binding(\.sideHeight), range: 0.4...0.8, suffix: "%", percentage: true, detents: [0.45])
                    } else {
                        EditorSlider(model: model, title: "大小", value: binding(\.size), range: 0.12...0.6, suffix: "%", percentage: true)
                    }
                    // 每种布局都能调圆角：圆形预设 50 % 是正圆，拉小就是圆角方块；人像全屏没有圆角（小窗的圆角在“画面布局”）。
                    if !layout.isCameraFull {
                        EditorSlider(model: model, title: "圆角", value: binding(\.cornerRadius), range: 0...0.5, suffix: "%", percentage: true, detents: [0.14, 0.5])
                    }
                    // 镜头推近时人像随同一条包络缩小并淡一点，拉远时放回来（像 FocuSee）；在后与分屏的人像不参与。
                    if !layout.ignoresFocus {
                        Toggle(isOn: Binding(get: { model.edit.camera?.shrinkOnFocus == true }, set: { value in model.commit { $0.camera?.shrinkOnFocus = value } })) {
                            SettingLabel("聚焦时缩小人像", systemImage: "arrow.down.right.and.arrow.up.left")
                        }.toggleStyle(StudioToggleStyle())
                        if layout.shrinkOnFocus {
                            EditorSlider(model: model, title: "聚焦时缩放", value: binding(\.focusedScale), range: 0.4...1, suffix: "%", percentage: true, detents: [0.7])
                        }
                    }
                    Toggle(isOn: Binding(get: { model.edit.camera?.mirrored == true }, set: { value in model.commit { $0.camera?.mirrored = value } })) {
                        SettingLabel("镜像", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }.toggleStyle(StudioToggleStyle())
                    if !layout.ignoresFocus {
                        Toggle(isOn: Binding(get: { model.edit.camera?.shadow == true }, set: { value in model.commit { $0.camera?.shadow = value } })) {
                            SettingLabel("阴影", systemImage: "square.3.layers.3d")
                        }.toggleStyle(StudioToggleStyle())
                    }
                }
            }.disabled(model.edit.camera?.enabled != true)
            Button("重置人像布局") { model.commit { $0.camera = CameraLayout(); $0.layout.screenScale = 1; $0.layout.screenOffsetX = 0; $0.layout.screenOffsetY = 0 } }
                .buttonStyle(StudioButtonStyle(.secondary))
                .sheet(isPresented: $customizing) { CustomLayoutSheet(model: model, stills: customStills ?? CustomLayoutStills()) }
        } else if model.cameraClipsDeleted {
            PanelNote("摄像头片段已从时间线删除。撤销可以恢复。")
        } else {
            PanelNote("此录制没有摄像头素材。下次录制前可在录制条开启摄像头。")
        }
    }

    /// 水平翻转：人像布局左右互换，自定义摆过的录屏也换到对侧。
    static func flip(_ edit: inout VideoEdit) {
        edit.camera = edit.camera?.flippedHorizontally()
        edit.layout.screenOffsetX = -edit.layout.screenOffsetX
    }

    private func binding(_ key: WritableKeyPath<CameraLayout, Double>) -> Binding<Double> {
        Binding(get: { (model.edit.camera ?? CameraLayout())[keyPath: key] }, set: { value in model.edit.camera?[keyPath: key] = value })
    }
}

/// 布局缩略图：深色小画布上，浅色块是录屏、强调色块是人像，按预设摆位。
private struct LayoutThumbnail: View {
    let preset: CameraPanel.Preset

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 7
            let inner = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
            let screenColor = CaploColor.textTertiary.opacity(0.45), cameraColor = CaploColor.accent
            if preset.mode == .overlay {
                context.fill(Path(roundedRect: inner, cornerRadius: 3), with: .color(screenColor))
                let edge = inner.height * 0.46
                let width = preset.shape == .circle ? edge : edge * 4 / 3
                let origin = CGPoint(x: preset.x == 0 ? inner.minX + 4 : inner.maxX - 4 - width,
                                     y: preset.y == 0 ? inner.minY + 4 : inner.maxY - 4 - edge)
                let rect = CGRect(origin: origin, size: CGSize(width: width, height: edge))
                context.fill(preset.shape == .circle ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 3), with: .color(cameraColor))
            } else if preset.mode == .cameraFull {
                // 人像全屏：整个画布是人像，右下角一个录屏小窗。
                context.fill(Path(roundedRect: inner, cornerRadius: 3), with: .color(cameraColor))
                let window = CGRect(x: inner.maxX - inner.width * 0.38 - 4, y: inner.maxY - inner.height * 0.38 - 4, width: inner.width * 0.38, height: inner.height * 0.38)
                context.fill(Path(roundedRect: window, cornerRadius: 3), with: .color(screenColor))
                context.stroke(Path(roundedRect: window, cornerRadius: 3), with: .color(.white.opacity(0.4)), lineWidth: 1)
            } else if preset.mode == .splitLeading {
                // 分屏：左窄右宽两个圆角块并排同高，整行缩到宽度刚好放下。
                let gap: CGFloat = 4
                let height = min(inner.height, (inner.width - gap) / (0.6 + 16 / 9))
                let total = height * (0.6 + 16 / 9) + gap
                let x = inner.midX - total / 2, y = inner.midY - height / 2
                let camera = CGRect(x: x, y: y, width: height * 0.6, height: height)
                let screen = CGRect(x: camera.maxX + gap, y: y, width: height * 16 / 9, height: height)
                context.fill(Path(roundedRect: screen, cornerRadius: 3), with: .color(screenColor))
                context.fill(Path(roundedRect: camera, cornerRadius: 3), with: .color(cameraColor))
            } else if preset.mode == .sideLeading {
                // 侧边：小竖卡片贴左、垂直居中，三分之二压在录屏边缘上；录屏向右靠。
                let cardHeight = inner.height * 0.66, cardWidth = cardHeight * 0.6
                let camera = CGRect(x: inner.minX, y: inner.midY - cardHeight / 2, width: cardWidth, height: cardHeight)
                let remaining = CGRect(x: inner.minX + cardWidth / 3, y: inner.minY, width: inner.width - cardWidth / 3, height: inner.height)
                let height = min(remaining.height, remaining.width * 9 / 16)
                let screen = CGRect(x: remaining.minX, y: remaining.midY - height / 2, width: remaining.width, height: height)
                context.fill(Path(roundedRect: screen, cornerRadius: 3), with: .color(screenColor))
                context.fill(Path(roundedRect: camera, cornerRadius: 3), with: .color(cameraColor))
            } else {
                // 在后：大竖卡片贴右、垂直居中，垫在录屏后面；录屏向左靠并压住卡片左侧四分之一。
                let cardHeight = inner.height * 0.92, cardWidth = cardHeight * 0.6
                let camera = CGRect(x: inner.maxX - cardWidth, y: inner.midY - cardHeight / 2, width: cardWidth, height: cardHeight)
                let available = CGRect(x: inner.minX, y: inner.minY, width: camera.minX + cardWidth / 4 - inner.minX, height: inner.height)
                let height = min(available.height, available.width * 9 / 16)
                let screen = CGRect(x: available.minX, y: available.midY - height / 2, width: available.width, height: height)
                context.fill(Path(roundedRect: camera, cornerRadius: 3), with: .color(cameraColor))
                context.fill(Path(roundedRect: screen, cornerRadius: 3), with: .color(screenColor))
            }
        }
        .frame(height: 64)
        .frame(maxWidth: .infinity)
    }
}

/// 缩略图按钮：软底、选中强调色描边，与 chip 一致。
private struct LayoutTileStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(selected ? CaploColor.accentSoft : CaploColor.surfaceRaised, in: RoundedRectangle(cornerRadius: CaploMetrics.Radius.control))
            .overlay { RoundedRectangle(cornerRadius: CaploMetrics.Radius.control).strokeBorder(selected ? CaploColor.accent : CaploColor.separator, lineWidth: 1) }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control))
    }
}

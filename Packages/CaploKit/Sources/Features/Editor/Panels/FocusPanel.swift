import SwiftUI
import CaploDesignSystem
import EditingCore

/// 镜头聚焦：自动聚焦开关、镜头列表与选中镜头的参数。
struct FocusPanel: View {
    let model: VideoEditorModel
    @State private var generating = false
    /// 折叠状态用本地状态驱动动画（AppStorage 的变化经偏好通知异步回流，不在动画事务里，折叠会"跳"），再手动写回偏好。
    @State private var autoParametersExpanded: Bool
    private static let autoParametersKey = "editor.focus.autoParametersExpanded"

    init(model: VideoEditorModel) {
        self.model = model
        _autoParametersExpanded = State(initialValue: UserDefaults.standard.object(forKey: Self.autoParametersKey) as? Bool ?? false)
    }

    /// 单个镜头的参数：跟随、缓动、推近 / 拉远、倍率、位置，最后是删除。起止时间只在时间线上拖。
    @ViewBuilder private func controls(for id: UUID, focus: FocusSegment) -> some View {
                Toggle("跟随鼠标", isOn: Binding(get: { focus.followsTimeline == true || focus.path != nil }, set: { enabled in
                    Task { await model.setFocusFollowing(id, enabled: enabled) }
                })).toggleStyle(StudioToggleStyle())
                Picker("缓动风格", selection: Binding(get: { focus.easing ?? .smooth }, set: { value in
                    model.commit { edit in
                        guard let index = edit.focuses.firstIndex(where: { $0.id == id }) else { return }
                        edit.focuses[index].easing = value; edit.focuses[index].automatic = false
                    }
                })) {
                    Text("柔和平滑").tag(FocusSegment.Easing.smooth)
                    Text("演示推近").tag(FocusSegment.Easing.demo)
                }.environment(\.colorScheme, .dark)
                EditorSlider(model: model, title: "推近时长", value: optionalBinding(id, \.easeIn, fallback: 0.6), range: 0.05...2, defaultValue: 0.6)
                EditorSlider(model: model, title: "拉远时长", value: optionalBinding(id, \.easeOut, fallback: 0.7), range: 0.05...2, defaultValue: 0.7)
                EditorSlider(model: model, title: "缩放倍率", value: binding(id, \.scale), range: 1...3, suffix: "×", detents: [1.5, 2, 2.5])
                EditorSlider(model: model, title: "水平位置", value: binding(id, \.x), range: 0...1, detents: [0.5])
                EditorSlider(model: model, title: "垂直位置", value: binding(id, \.y), range: 0...1, detents: [0.5])
        Button("删除此镜头") { model.selectedFocus = id; model.deleteSelection() }.buttonStyle(StudioButtonStyle(.destructive, size: .small))
    }

    var body: some View {
        Toggle(isOn: Binding(get: { model.edit.automaticFocus }, set: { value in model.commit { $0.automaticFocus = value } })) {
            SettingLabel("自动聚焦", systemImage: "sparkles",
                         tip: "按点击推近，提前读取鼠标轨迹并平滑跟随。不点鼠标的讲解也能聚焦：在时间线右键“在此处添加聚焦”，镜头会推近到指针所在并跟着走。相邻镜头间隔小于合并间隔时直接平移过去，不拉远。手动指定水平或垂直位置后改为固定聚焦。")
        }.toggleStyle(StudioToggleStyle())
        // 默认收起，专注于各镜头的参数；需要时展开调整。状态随偏好保留。
        PanelSection("自动聚焦设置", expanded: $autoParametersExpanded) {
            EditorSlider(model: model, title: "默认缩放倍率", value: styleBinding(\.baseScale), range: 1...3, suffix: "×", detents: [1.5, 2, 2.5])
            EditorSlider(model: model, title: "拉远延迟", value: styleBinding(\.idleTimeout), range: 0.5...5)
            EditorSlider(model: model, title: "合并间隔", value: styleBinding(\.mergeGap), range: 0...2)
            EditorSlider(model: model, title: "提前对准", value: optionalStyleBinding(\.prediction, fallback: 0.21), range: 0...0.4)
            EditorSlider(model: model, title: "跟随平滑度", value: optionalStyleBinding(\.panResponse, fallback: 0.55), range: 0.15...1.5)
            EditorSlider(model: model, title: "安全区", value: optionalStyleBinding(\.clusterWidth, fallback: 0.5), range: 0.2...0.9)
            Button(generating ? "正在生成…" : "重新生成自动镜头") {
                generating = true
                Task { await model.regenerateFocus(); generating = false }
            }.buttonStyle(StudioButtonStyle(.secondary)).disabled(generating)
        }
        // 挑哪一个镜头是时间线的事：这里只显示时间线上选中的那一个，换一块内容跟着换。
        PanelSection("镜头") {
            if let id = model.selectedFocus, let focus = model.edit.focuses.first(where: { $0.id == id }) {
                PanelSelection(symbol: focus.automatic ? "sparkles" : "viewfinder",
                               title: model.edit.focusDisplayTitle(focus, numbers: model.edit.focusNumbers()),
                               trailing: timecode(focus.editingStart)) {
                    controls(for: id, focus: focus)
                }
            } else if model.edit.focuses.isEmpty {
                PanelNote("暂无镜头。在时间线右键“在此处添加聚焦”，或用工具栏按钮在播放头处添加 2 秒镜头。")
            } else {
                PanelNote("在时间线的镜头块上点一下，这里就显示那一个的参数。")
            }
        }
        // 进面板时还没选中就先选第一个，免得面板空着、非得先去时间线点一下。
        .onAppear { if model.selectedFocus == nil { model.selectedFocus = model.edit.focuses.first?.id } }
        .onChange(of: autoParametersExpanded) { _, value in UserDefaults.standard.set(value, forKey: Self.autoParametersKey) }
    }

    private func optionalStyleBinding(_ key: WritableKeyPath<AutoFocusStyle, Double?>, fallback: Double) -> Binding<Double> {
        Binding(get: { (model.edit.focusStyle ?? AutoFocusStyle())[keyPath: key] ?? fallback }, set: { value in
            if model.edit.focusStyle == nil { model.edit.focusStyle = AutoFocusStyle() }
            model.edit.focusStyle?[keyPath: key] = value
        })
    }

    private func styleBinding(_ key: WritableKeyPath<AutoFocusStyle, Double>) -> Binding<Double> {
        Binding(get: { (model.edit.focusStyle ?? AutoFocusStyle())[keyPath: key] }, set: { value in
            if model.edit.focusStyle == nil { model.edit.focusStyle = AutoFocusStyle() }
            model.edit.focusStyle?[keyPath: key] = value
        })
    }

    private func optionalBinding(_ id: UUID, _ key: WritableKeyPath<FocusSegment, Double?>, fallback: Double) -> Binding<Double> {
        Binding(get: { model.edit.focuses.first(where: { $0.id == id })?[keyPath: key] ?? fallback }, set: { value in
            guard let index = model.edit.focuses.firstIndex(where: { $0.id == id }) else { return }
            model.edit.focuses[index][keyPath: key] = value
            model.edit.focuses[index].automatic = false
        })
    }

    private func binding(_ id: UUID, _ key: WritableKeyPath<FocusSegment, Double>) -> Binding<Double> {
        Binding(get: { model.edit.focuses.first(where: { $0.id == id })?[keyPath: key] ?? 0 }, set: { value in
            guard let index = model.edit.focuses.firstIndex(where: { $0.id == id }) else { return }
            // 时间参数与块拖边走同一路径；直接改 duration 会留下范围外的自动关键帧，
            // 尤其是分割镜头的 transitionOffset 尚未展开时，松手校验会撤回整个修改。
            if key == \.editingStart {
                model.edit.dragFocus(id: id, edge: .body, delta: value - model.edit.focuses[index].editingStart)
                return
            }
            if key == \.duration {
                model.edit.dragFocus(id: id, edge: .trailing, delta: value - model.edit.focuses[index].duration)
                return
            }
            model.edit.focuses[index][keyPath: key] = value
            // 指定坐标表示固定取景；仅调倍率仍保留时间线跟随，规划器会按新安全区重算路径。
            model.edit.focuses[index].automatic = false
            model.edit.focuses[index].transitionOffset = nil; model.edit.focuses[index].transitionDuration = nil
            // 旧自动镜头以 path 表示跟随；改倍率时先迁移意图，不能清路径后把开启的开关误关掉。
            if key == \.scale, model.edit.focuses[index].timelineStart != nil,
               model.edit.focuses[index].path != nil, model.edit.focuses[index].followsTimeline != false {
                model.edit.focuses[index].followsTimeline = true
            }
            if key == \.x || key == \.y || key == \.scale { model.edit.focuses[index].path = nil }
            if key == \.x || key == \.y { model.edit.focuses[index].followsTimeline = false }
        })
    }
}

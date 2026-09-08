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
    /// 当前展开的镜头；面板创建时按已选中的镜头展开。
    @State private var expanded: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: VideoEditorModel) {
        self.model = model
        _expanded = State(initialValue: model.selectedFocus)
        _autoParametersExpanded = State(initialValue: UserDefaults.standard.object(forKey: Self.autoParametersKey) as? Bool ?? true)
    }

    private func toggle(_ id: UUID) {
        withAnimation(CaploMotion.animation(0.22, reduceMotion: reduceMotion)) {
            if expanded == id { expanded = nil } else { expanded = id; model.selectedFocus = id }
        }
    }

    /// 单个镜头的参数：跟随、缓动、推近 / 拉远、倍率、位置、起点与时长，最后是删除。
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
                EditorSlider(model: model, title: "推近秒数", value: optionalBinding(id, \.easeIn, fallback: 0.6), range: 0.05...2, defaultValue: 0.6)
                EditorSlider(model: model, title: "拉远秒数", value: optionalBinding(id, \.easeOut, fallback: 0.7), range: 0.05...2, defaultValue: 0.7)
                EditorSlider(model: model, title: "倍率", value: binding(id, \.scale), range: 1...3, suffix: "×", detents: [1.5, 2, 2.5])
                EditorSlider(model: model, title: "水平位置", value: binding(id, \.x), range: 0...1, detents: [0.5])
                EditorSlider(model: model, title: "垂直位置", value: binding(id, \.y), range: 0...1, detents: [0.5])
                if let bounds = model.edit.focusBounds(for: id) {
                    EditorSlider(model: model, title: focus.timelineStart == nil ? "起点（原素材秒）" : "起点（时间线秒）", value: binding(id, \.editingStart), range: bounds.lowerBound...max(bounds.lowerBound, bounds.upperBound - focus.duration))
                    let minimum = min(1.0 / 30, focus.duration, max(0.000001, bounds.upperBound - focus.editingStart))
                    EditorSlider(model: model, title: "持续秒数", value: binding(id, \.duration), range: minimum...max(minimum, bounds.upperBound - focus.editingStart))
                }
        Button("删除此镜头") { model.selectedFocus = id; model.deleteSelection() }.buttonStyle(StudioButtonStyle(.destructive, size: .small))
    }

    var body: some View {
        Toggle(isOn: Binding(get: { model.edit.automaticFocus }, set: { value in model.commit { $0.automaticFocus = value } })) {
            SettingLabel("自动聚焦", systemImage: "sparkles")
        }.toggleStyle(StudioToggleStyle())
        PanelNote("按点击推近，提前读取鼠标轨迹并平滑跟随。镜头可跨片段延长，自动识别范围内的目标；手动指定水平或垂直位置后改为固定聚焦。")
        // 默认展开；镜头多时可以收起，专注于各镜头的参数。状态随偏好保留。
        PanelSection("自动镜头参数", expanded: $autoParametersExpanded) {
            EditorSlider(model: model, title: "默认倍率", value: styleBinding(\.baseScale), range: 1...3, suffix: "×", detents: [1.5, 2, 2.5])
            EditorSlider(model: model, title: "停留秒数", value: styleBinding(\.idleTimeout), range: 0.5...5)
            EditorSlider(model: model, title: "镜头合并间隔", value: styleBinding(\.mergeGap), range: 0...2)
            EditorSlider(model: model, title: "轨迹前瞻（秒）", value: optionalStyleBinding(\.prediction, fallback: 0.16), range: 0...0.4)
            EditorSlider(model: model, title: "镜头平滑响应", value: optionalStyleBinding(\.panResponse, fallback: 0.55), range: 0.15...1.5)
            EditorSlider(model: model, title: "中心安全区", value: styleBinding(\.safeZone), range: 0.2...0.9)
            Button(generating ? "正在生成…" : "重新生成自动镜头") {
                generating = true
                Task { await model.regenerateFocus(); generating = false }
            }.buttonStyle(StudioButtonStyle(.secondary)).disabled(generating)
        }
        PanelSection("镜头") {
            if model.edit.focuses.isEmpty {
                PanelNote("暂无镜头。可在播放头位置添加手动聚焦。")
            } else {
                // 每个镜头是一个可展开条目：默认收起只占一行，点开向下展开这个镜头的参数；展开即选中，时间线里选中也会展开。
                VStack(spacing: CaploMetrics.Spacing.xs) {
                    ForEach(model.edit.focuses) { focus in
                        FocusDisclosure(focus: focus, expanded: expanded == focus.id, toggle: { toggle(focus.id) }) {
                            controls(for: focus.id, focus: focus)
                        }
                    }
                }
            }
        }
        .onChange(of: model.selectedFocus) { _, selected in
            guard let selected, selected != expanded else { return }
            withAnimation(CaploMotion.animation(0.22, reduceMotion: reduceMotion)) { expanded = selected }
        }
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

/// 可展开的镜头条目：一行表头（图标、起点、倍率、箭头），展开后表头高亮、下面是参数；高度变化带动画，整体裁成圆角卡片。
private struct FocusDisclosure<Content: View>: View {
    let focus: FocusSegment
    let expanded: Bool
    let toggle: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovered = false
    private var radius: CGFloat { CaploMetrics.Radius.control + 2 }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                // 表头显示与时间线块相同的名字（自定义名优先），右侧是起点时间码。
                HStack(spacing: CaploMetrics.Spacing.s) {
                    Image(systemName: focus.automatic ? "sparkles" : "viewfinder").frame(width: CaploMetrics.Icon.control)
                    Text(focus.displayTitle).font(CaploFont.bodyMedium).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: CaploMetrics.Spacing.s)
                    Text(timecode(focus.editingStart)).font(CaploFont.value).foregroundStyle(expanded ? CaploColor.textPrimary : CaploColor.textSecondary)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(CaploColor.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 10).frame(height: CaploMetrics.ControlHeight.large)
                .foregroundStyle(CaploColor.textPrimary)
                .background(expanded ? CaploColor.accentSoft : CaploColor.surfaceRaised.opacity(hovered ? 1 : 0.8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityAddTraits(expanded ? .isSelected : [])
            .accessibilityValue(expanded ? "已展开" : "已收起")
            if expanded {
                VStack(alignment: .leading, spacing: CaploMetrics.Spacing.s) { content() }
                    .padding(.horizontal, 10).padding(.top, CaploMetrics.Spacing.s).padding(.bottom, CaploMetrics.Spacing.m)
                    .background(CaploColor.surfaceRaised.opacity(0.5))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(expanded ? CaploColor.accent : CaploColor.separator, lineWidth: expanded ? 1.5 : 1))
    }
}


import SwiftUI
import CaploDesignSystem
import EditingCore

/// 文字层：预设、文本、排版、外观与进出动画。
///
/// 文字定位在输出画面上，不跟着镜头推近一起放大；时间存在原素材上，剪掉中间一段文字会自己裂成两段。
struct TextPanel: View {
    let model: VideoEditorModel
    @State private var expanded: UUID?
    @State private var typographyExpanded: Bool
    @State private var appearanceExpanded: Bool
    private static let typographyKey = "editor.text.typographyExpanded"
    private static let appearanceKey = "editor.text.appearanceExpanded"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: VideoEditorModel) {
        self.model = model
        _expanded = State(initialValue: model.selectedText)
        _typographyExpanded = State(initialValue: UserDefaults.standard.object(forKey: Self.typographyKey) as? Bool ?? false)
        _appearanceExpanded = State(initialValue: UserDefaults.standard.object(forKey: Self.appearanceKey) as? Bool ?? false)
    }

    private func toggle(_ id: UUID) {
        withAnimation(CaploMotion.animation(0.22, reduceMotion: reduceMotion)) {
            if expanded == id { expanded = nil } else { expanded = id; model.selectedText = id; model.reveal(id) }
        }
    }

    var body: some View {
        PanelSection("预设", info: "预设只是一组排版与动画的初值，套用之后每一项都还能单独改。") {
            let current = model.selectedText.flatMap { model.edit.text(id: $0) }
            let matched = current.flatMap { TextPreset.matching($0) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: CaploMetrics.Spacing.xs), GridItem(.flexible(), spacing: CaploMetrics.Spacing.xs)],
                      spacing: CaploMetrics.Spacing.xs) {
                ForEach(TextPreset.allCases) { preset in
                    PresetTile(preset: preset, selected: matched == preset) { apply(preset) }
                }
            }
        }
        PanelSection("文字") {
            if model.edit.textList.isEmpty {
                PanelNote("暂无文字。挑一个预设，或用下面的按钮在播放头处添加 3 秒文字。")
            } else {
                let numbers = model.edit.textNumbers()
                VStack(spacing: CaploMetrics.Spacing.xs) {
                    ForEach(model.edit.textList) { value in
                        PanelDisclosure(symbol: "text.alignleft",
                                        title: model.edit.textDisplayTitle(value, numbers: numbers),
                                        trailing: timecode(value.timelineStart ?? value.start),
                                        expanded: expanded == value.id, toggle: { toggle(value.id) }) {
                            controls(for: value.id, value: value)
                        }
                    }
                }
            }
            HStack(spacing: CaploMetrics.Spacing.s) {
                Button("添加文字") { if let id = model.addText() { toggle(id) } }.buttonStyle(StudioButtonStyle(.secondary))
                Button("添加全屏卡段") { if let id = model.addHoldCard() { toggle(id) } }
                    .buttonStyle(StudioButtonStyle(.secondary))
                    .help("在播放头处插进一段定格：画面停住、声音静音，文字占满全屏，成片会因此变长。")
            }
        }
        .onAppear { model.textEditing = true }
        .onDisappear { model.textEditing = false }
        .onChange(of: model.selectedText) { _, selected in
            guard let selected, selected != expanded else { return }
            withAnimation(CaploMotion.animation(0.22, reduceMotion: reduceMotion)) { expanded = selected }
        }
        .onChange(of: typographyExpanded) { _, value in UserDefaults.standard.set(value, forKey: Self.typographyKey) }
        .onChange(of: appearanceExpanded) { _, value in UserDefaults.standard.set(value, forKey: Self.appearanceKey) }
    }

    /// 单段文字的参数：文本框、版式、动画，然后是收起的排版与外观。起止时间只在时间线上拖。
    @ViewBuilder private func controls(for id: UUID, value: TextSegment) -> some View {
        TextEditor(text: textBinding(id))
            .font(CaploFont.body).scrollContentBackground(.hidden)
            .frame(minHeight: 62)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(CaploColor.surfaceRaised, in: RoundedRectangle(cornerRadius: CaploMetrics.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control, style: .continuous).strokeBorder(CaploColor.separator, lineWidth: 1))
        // 标题单独占一行：四个中文选项的分段控件本身就要 227 点，标题挤在同一行会被压成两行竖排。
        VStack(alignment: .leading, spacing: CaploMetrics.Spacing.xs) {
            Text("版式").font(CaploFont.body).foregroundStyle(CaploColor.textPrimary)
            Picker("版式", selection: layoutBinding(id)) {
                ForEach(TextSegment.Layout.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().pickerStyle(.segmented).environment(\.colorScheme, .dark)
        }
        // 卡段的版式定死在全屏：那段定格是按"整幅画面都被文字盖住"插进成片的。
        .disabled(value.holdClipID != nil)
        if value.layout != .overlay {
            PanelNote(value.layout == .fullscreen
                      ? "全屏：文字占满画面，底下的录制画面缩一点并淡出。要让成片在这里停住，再打开下面的「插入时长」。"
                      : "分屏：录制画面退到一栏，文字占另一栏。浮在画面上的画中画会待在画面那一栏里，不跟着画面一起缩小。")
            EditorSlider(model: model, title: "版式过渡", value: binding(id, \.layoutTransition), range: 0...3, defaultValue: 0.35)
        }
        if value.layout.textOnLeft != nil {
            // 人像被当成画面构图一部分的那几种布局（侧边 / 在后 / 分屏 / 人像全屏）没法摘出来单独摆，
            // 摘了整套构图就散了。这里说清楚，免得用户以为是画中画没生效。
            if model.hasCameraMedia, let camera = model.edit.camera, camera.enabled, !camera.isFloatingPortrait {
                PanelNote("人像当前不是浮在画面上的画中画，它属于画面构图的一部分，会跟着画面一起缩进这一栏。想让人像保持原大小，去「人像」面板换成圆形或圆角矩形那两种叠放预设。")
            }
            EditorSlider(model: model, title: "画面占比", value: binding(id, \.splitRatio), range: TextSegment.splitRatioRange,
                         suffix: "%", percentage: true, defaultValue: TextSegment.defaultSplitRatio, detents: [0.5])
            EditorSlider(model: model, title: "分栏间距", value: binding(id, \.splitGap), range: 0...240, decimals: 0,
                         defaultValue: TextSegment.defaultSplitGap)
        }
        if value.layout == .fullscreen {
            Toggle("插入时长（时钟暂停）", isOn: holdBinding(id)).toggleStyle(StudioToggleStyle())
                .help("打开之后成片会在这里停住：画面定格、声音静音，这一段是真实增加的时长。")
        }
        if value.holdClipID != nil {
            // 起止时间一律在时间线上拖，面板不再放重复的卡尺。
            PanelNote("这一段是插进成片里的定格，长度在时间线上拖这一块的右缘来改，后面的所有内容跟着往后挪。")
        }
        Picker("进场动画", selection: animationBinding(id, \.enterKind)) { animationOptions }.environment(\.colorScheme, .dark)
        EditorSlider(model: model, title: "进场时长", value: binding(id, \.enterDuration), range: 0...3, defaultValue: 0.4)
        Picker("出场动画", selection: animationBinding(id, \.exitKind)) { animationOptions }.environment(\.colorScheme, .dark)
        EditorSlider(model: model, title: "出场时长", value: binding(id, \.exitDuration), range: 0...3, defaultValue: 0.35)
        if value.enterDuration + value.exitDuration > value.duration {
            PanelNote("进出时长之和超过了本段时长，已按比例压缩。")
        }
        PanelSection("排版", expanded: $typographyExpanded) {
            Picker("字体族", selection: familyBinding(id)) {
                Text("系统").tag(TextSegment.Family.system)
                Text("无衬线").tag(TextSegment.Family.sans)
                Text("衬线").tag(TextSegment.Family.serif)
                Text("圆体").tag(TextSegment.Family.rounded)
                Text("等宽").tag(TextSegment.Family.mono)
            }.environment(\.colorScheme, .dark)
            EditorSlider(model: model, title: "字号", value: binding(id, \.size), range: TextSegment.sizeRange,
                         decimals: 0, detents: [26, 40, 44, 56, 96, 160])
            EditorSlider(model: model, title: "字重", value: binding(id, \.weight), range: TextSegment.weightRange,
                         decimals: 0, defaultValue: 500, detents: [400, 700])
            Toggle("斜体", isOn: boolBinding(id, \.italic)).toggleStyle(StudioToggleStyle())
            EditorSlider(model: model, title: "行高", value: binding(id, \.lineHeight), range: 0.8...2.0, defaultValue: 1.30, detents: [1.0, 1.3])
            EditorSlider(model: model, title: "字距", value: binding(id, \.tracking), range: -2...20, decimals: 1, defaultValue: 0, detents: [0])
            EditorSlider(model: model, title: "水平位置", value: binding(id, \.x), range: 0...1, suffix: "%", percentage: true, detents: [0.5])
            EditorSlider(model: model, title: "垂直位置", value: binding(id, \.y), range: 0...1, suffix: "%", percentage: true, detents: [0.5])
            EditorSlider(model: model, title: "最大宽度", value: binding(id, \.maxWidth), range: 0.2...1, suffix: "%", percentage: true, defaultValue: 0.8)
        }
        PanelSection("外观", expanded: $appearanceExpanded) {
            SwatchRow(title: "文字颜色", selection: paletteBinding(id, \.color))
            EditorSlider(model: model, title: "不透明度", value: binding(id, \.opacity), range: 0...1, suffix: "%", percentage: true, defaultValue: 1)
            Toggle("文字底色", isOn: boolBinding(id, \.plate)).toggleStyle(StudioToggleStyle())
            if value.plate {
                SwatchRow(title: "底色", selection: paletteBinding(id, \.plateColor))
                EditorSlider(model: model, title: "底色不透明度", value: binding(id, \.plateOpacity), range: 0...1, suffix: "%", percentage: true, defaultValue: 0.55)
                EditorSlider(model: model, title: "内边距", value: binding(id, \.platePadding), range: 0...48, decimals: 0, defaultValue: 16)
                EditorSlider(model: model, title: "底色圆角", value: binding(id, \.plateRadius), range: 0...32, decimals: 0, defaultValue: 8)
                Toggle("铺满整行", isOn: boolBinding(id, \.plateFull)).toggleStyle(StudioToggleStyle())
            }
            Toggle("阴影", isOn: boolBinding(id, \.shadow)).toggleStyle(StudioToggleStyle())
            if value.shadow {
                EditorSlider(model: model, title: "阴影不透明度", value: binding(id, \.shadowOpacity), range: 0...1, suffix: "%", percentage: true, defaultValue: 0.45)
                EditorSlider(model: model, title: "柔和度", value: binding(id, \.shadowBlur), range: 0...60, decimals: 0, defaultValue: 18)
                EditorSlider(model: model, title: "距离", value: binding(id, \.shadowOffset), range: -40...40, decimals: 0, defaultValue: 6, detents: [0])
            }
        }
        HStack(spacing: CaploMetrics.Spacing.s) {
            Button("复制这段") { model.selectedText = id; model.duplicateSelection() }.buttonStyle(StudioButtonStyle(.secondary, size: .small))
            Button("删除这段") { model.selectedText = id; model.deleteSelection() }.buttonStyle(StudioButtonStyle(.destructive, size: .small))
        }
    }

    @ViewBuilder private var animationOptions: some View {
        Text("无").tag(TextSegment.Animation.none)
        Text("淡入淡出").tag(TextSegment.Animation.fade)
        Text("上滑").tag(TextSegment.Animation.slideUp)
        Text("下滑").tag(TextSegment.Animation.slideDown)
        Text("弹出").tag(TextSegment.Animation.pop)
        Text("打字机").tag(TextSegment.Animation.type)
    }

    /// 点预设：已经选中一段就把预设套上去（文本、时间、版式、卡段归属都保留），否则新建一段。
    private func apply(_ preset: TextPreset) {
        guard let id = model.selectedText, model.edit.text(id: id) != nil else {
            if let created = model.addText(preset: preset) { toggle(created) }
            return
        }
        model.commit { edit in
            edit.updateText(id: id) { $0 = preset.applied(to: $0) }
        }
    }

    // MARK: 绑定

    private func binding(_ id: UUID, _ key: WritableKeyPath<TextSegment, Double>) -> Binding<Double> {
        Binding(get: { model.edit.text(id: id)?[keyPath: key] ?? 0 }, set: { value in
            model.edit.updateText(id: id) { $0[keyPath: key] = value }
        })
    }
    private func boolBinding(_ id: UUID, _ key: WritableKeyPath<TextSegment, Bool>) -> Binding<Bool> {
        Binding(get: { model.edit.text(id: id)?[keyPath: key] ?? false }, set: { value in
            model.commit { $0.updateText(id: id) { $0[keyPath: key] = value } }
        })
    }
    private func textBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { model.edit.text(id: id)?.text ?? "" }, set: { value in
            // 逐字提交会把撤销栈灌满；打字期间只改预览，停手 0.6 秒后合成一个快照。
            model.edit.updateText(id: id) { $0.text = String(value.prefix(TextSegment.textLimit)) }
            model.scheduleTextCommit()
        })
    }
    private func animationBinding(_ id: UUID, _ key: WritableKeyPath<TextSegment, TextSegment.Animation>) -> Binding<TextSegment.Animation> {
        Binding(get: { model.edit.text(id: id)?[keyPath: key] ?? .fade }, set: { value in
            model.commit { $0.updateText(id: id) { $0[keyPath: key] = value } }
        })
    }
    private func familyBinding(_ id: UUID) -> Binding<TextSegment.Family> {
        Binding(get: { model.edit.text(id: id)?.family ?? .system }, set: { value in
            model.commit { $0.updateText(id: id) { $0.family = value } }
        })
    }
    private func layoutBinding(_ id: UUID) -> Binding<TextSegment.Layout> {
        Binding(get: { model.edit.text(id: id)?.layout ?? .overlay }, set: { value in
            // 卡段的版式必须留在全屏：定格片段是按"整幅画面都被文字盖住"插进去的。
            guard model.edit.text(id: id)?.holdClipID == nil else { return }
            model.commit { $0.updateText(id: id) { $0.layout = value } }
        })
    }
    private func holdBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { model.edit.text(id: id)?.holdClipID != nil }, set: { model.setHoldCard(id, enabled: $0) })
    }
    private func paletteBinding(_ id: UUID, _ key: WritableKeyPath<TextSegment, TextSegment.Palette>) -> Binding<TextSegment.Palette> {
        Binding(get: { model.edit.text(id: id)?[keyPath: key] ?? .auto }, set: { value in
            model.commit { $0.updateText(id: id) { $0[keyPath: key] = value } }
        })
    }
}

/// 预设格：上半按该预设的字号字重画样例文，下半是名称。
private struct PresetTile: View {
    let preset: TextPreset
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let sample = preset.segment(start: 0, duration: 3)
        Button(action: action) {
            VStack(spacing: 2) {
                Text(preset.sample)
                    // 样例文的大小按预设字号在 26…160 之间线性铺开，格子之间一眼看得出层级差别。
                    .font(.system(size: 9 + min(1, max(0, (sample.size - 26) / 134)) * 13,
                                  weight: Font.Weight.from(sample.weight),
                                  design: sample.family.design))
                    .italic(sample.italic)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(preset.name).font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
            }
            .padding(.vertical, 6).padding(.horizontal, 4)
            .frame(height: 62)
            .frame(maxWidth: .infinity)
            .background(selected ? CaploColor.accentSoft : CaploColor.surfaceRaised.opacity(hovered ? 1 : 0.8))
            .clipShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control, style: .continuous)
                .strokeBorder(selected ? CaploColor.accent : CaploColor.separator, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// 八格色板。
private struct SwatchRow: View {
    let title: String
    @Binding var selection: TextSegment.Palette

    var body: some View {
        VStack(alignment: .leading, spacing: CaploMetrics.Spacing.xs) {
            Text(title).font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
            HStack(spacing: CaploMetrics.Spacing.xs) {
                ForEach(TextSegment.Palette.allCases, id: \.self) { palette in
                    Button { selection = palette } label: {
                        swatch(palette)
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(selection == palette ? CaploColor.accent : CaploColor.separator,
                                              lineWidth: selection == palette ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(palette.title)
                }
            }
        }
    }

    @ViewBuilder private func swatch(_ palette: TextSegment.Palette) -> some View {
        if palette == .auto {
            // 「自动」画成半黑半白的斜分格，一眼看出它会按背景选色。
            ZStack {
                LinearGradient(stops: [.init(color: .white, location: 0.5), .init(color: Color(red: 0.086, green: 0.086, blue: 0.102), location: 0.5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text("A").font(.system(size: 10, weight: .bold)).foregroundStyle(CaploColor.textSecondary)
            }
        } else {
            let rgb = palette.rgb
            Color(red: rgb.0, green: rgb.1, blue: rgb.2)
        }
    }
}

extension Font.Weight {
    /// 300…900 就近取 SwiftUI 的字重档，与渲染端的映射保持一致。
    static func from(_ value: Double) -> Font.Weight {
        switch value {
        case ..<350: .light; case ..<450: .regular; case ..<550: .medium
        case ..<650: .semibold; case ..<750: .bold; case ..<850: .heavy; default: .black
        }
    }
}

extension TextSegment.Family {
    var design: Font.Design {
        switch self { case .serif: .serif; case .rounded: .rounded; case .mono: .monospaced; default: .default }
    }
}

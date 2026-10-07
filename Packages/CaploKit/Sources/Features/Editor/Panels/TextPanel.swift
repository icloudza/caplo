import AppKit
import SwiftUI
import CaploDesignSystem
import EditingCore

/// 文字层：预设、文本、排版、外观与进出动画。时间线上选中卡片时，这里改的是卡片上的字和卡片背景。
///
/// 文字定位在输出画面上，不跟着镜头推近一起放大；时间存在原素材上，剪掉中间一段文字会自己裂成两段。
struct TextPanel: View {
    let model: VideoEditorModel
    @State private var typographyExpanded: Bool
    @State private var appearanceExpanded: Bool
    private static let typographyKey = "editor.text.typographyExpanded"
    private static let appearanceKey = "editor.text.appearanceExpanded"

    init(model: VideoEditorModel) {
        self.model = model
        _typographyExpanded = State(initialValue: UserDefaults.standard.object(forKey: Self.typographyKey) as? Bool ?? false)
        _appearanceExpanded = State(initialValue: UserDefaults.standard.object(forKey: Self.appearanceKey) as? Bool ?? false)
    }

    /// 新建之后直接选中它并滚进视口——面板显示的永远是时间线上选中的那一段。
    private func select(_ id: UUID) { model.select(.text(id)); model.reveal(id) }
    /// 正在编辑的那段文字：选中的文字层，或选中卡片上的字。预设与下面的参数都作用在它上面。
    private var editingID: UUID? { model.editingTextID }

    var body: some View {
        PanelSection("预设", info: "套用后仍可逐项修改") {
            let current = editingID.flatMap { model.edit.text(id: $0) }
            let matched = current.flatMap { TextPreset.matching($0) }
            // 一行三个、格子矮一点：八个预设两行多就能看完，不占面板一大截。
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: CaploMetrics.Spacing.xs), count: 3),
                      spacing: CaploMetrics.Spacing.xs) {
                ForEach(TextPreset.allCases) { preset in
                    PresetTile(preset: preset, selected: matched == preset) { apply(preset) }
                }
            }
        }
        if let card = model.selectedCard, let content = card.card, let value = model.edit.text(id: content.text.id) {
            PanelSection("卡片") {
                PanelSelection(symbol: "rectangle.inset.filled", title: card.title ?? content.defaultTitle,
                               trailing: timecode(card.timelineStart ?? 0)) {
                    cardBackground(card.id, content: content)
                    controls(for: content.text.id, value: value, card: card.id)
                }
            }
        }
        PanelSection("文字") {
            if let id = model.selectedText, let value = model.edit.text(id: id) {
                PanelSelection(symbol: "text.alignleft",
                               title: model.edit.textDisplayTitle(value, numbers: model.edit.textNumbers()),
                               trailing: timecode(value.timelineStart ?? value.start)) {
                    controls(for: id, value: value)
                }
            } else if model.edit.textList.isEmpty {
                PanelNote("暂无文字。挑一个预设，或用下面的按钮在播放头处添加 3 秒文字。")
            } else {
                PanelNote("在时间线的文字块上点一下，这里就显示那一段的参数。")
            }
            Button("添加文字") { if let id = model.addText() { select(id) } }.buttonStyle(StudioButtonStyle(.secondary))
            PanelNote("片头、章节、片尾用卡片：时间线工具栏的“插入卡片”，或右键录制画面“在此前 / 后插入卡片”。")
        }
        // 进面板时还没选中任何一段就先选第一段，免得面板空着、非得先去时间线点一下。
        .onAppear {
            model.textEditing = true
            selectFirstIfNeeded()
        }
        // 面板可能比工程先出现（直接打开到这个面板时）：载入完成再补选一次。
        .onChange(of: model.ready) { selectFirstIfNeeded() }
        .onDisappear { model.textEditing = false }
        .onChange(of: typographyExpanded) { _, value in UserDefaults.standard.set(value, forKey: Self.typographyKey) }
        .onChange(of: appearanceExpanded) { _, value in UserDefaults.standard.set(value, forKey: Self.appearanceKey) }
    }

    /// 卡片背景：默认跟随画布背景（壁纸 / 渐变），也可以换成纯色。时长在时间线上拖。
    @ViewBuilder private func cardBackground(_ id: UUID, content: TitleCard) -> some View {
        Toggle("纯色背景", isOn: Binding(get: { content.background != nil }, set: { on in
            model.commit { $0.updateCard(id: id) { $0.background = on ? .ink : nil } }
        })).toggleStyle(StudioToggleStyle())
        if content.background != nil {
            SwatchRow(title: "背景色", selection: Binding(get: { model.selectedCard?.card?.background ?? .ink }, set: { color in
                model.commit { $0.updateCard(id: id) { $0.background = color } }
            }))
        } else {
            PanelNote("背景跟随画布（画面布局里的壁纸 / 渐变 / 纯色）。")
        }
        PanelNote("卡片期间不显示录屏、人像与光标，声音留空。时长在时间线上拖卡片右缘来改，后面的内容跟着挪。")
    }

    /// 单段文字的参数：文本框、版式、动画，然后是收起的排版与外观。起止时间只在时间线上拖。
    /// `card` 非空表示这是卡片上的字：没有版式可选（卡片独占整个画面），复制 / 删除作用于整块卡片。
    @ViewBuilder private func controls(for id: UUID, value: TextSegment, card: UUID? = nil) -> some View {
        TextEditor(text: textBinding(id))
            .font(CaploFont.body).scrollContentBackground(.hidden)
            .frame(minHeight: 62)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(CaploColor.surfaceRaised, in: RoundedRectangle(cornerRadius: CaploMetrics.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control, style: .continuous).strokeBorder(CaploColor.separator, lineWidth: 1))
        if card == nil {
            // 标题单独占一行：四个中文选项挤在标题同一行会被压成两行竖排。
            VStack(alignment: .leading, spacing: CaploMetrics.Spacing.xs) {
                Text("版式").font(CaploFont.body).foregroundStyle(CaploColor.textPrimary)
                SegmentedBar(TextSegment.Layout.allCases, selection: layoutBinding(id)) { $0.title }
                    .accessibilityLabel("版式")
            }
            if value.layout != .overlay {
                PanelNote(value.layout == .fullscreen
                          ? "全屏：文字占满画面，底下的录制画面缩一点并淡出，视频照常往下播。要让成片在这里停一会儿，用时间线上的“插入卡片”。"
                          : "分屏：录制画面退到一栏，文字占另一栏。浮在画面上的画中画会待在画面那一栏里，不跟着画面一起缩小。")
                EditorStepper(model: model, title: "过渡时长", value: binding(id, \.layoutTransition), range: 0...3, defaultValue: 0.35)
            }
            if value.layout.textOnLeft != nil {
                // 人像被当成画面构图一部分的那几种布局（侧边 / 在后 / 分屏 / 人像全屏）没法摘出来单独摆，
                // 摘了整套构图就散了。这里说清楚，免得用户以为是画中画没生效。
                if model.hasCameraMedia, let camera = model.edit.camera, camera.enabled, !camera.isFloatingPortrait {
                    PanelNote("人像当前不是浮在画面上的画中画，它属于画面构图的一部分，会跟着画面一起缩进这一栏。想让人像保持原大小，去「人像」面板换成圆形或圆角矩形那两种叠放预设。")
                }
                EditorFill(model: model, title: "画面栏宽", value: binding(id, \.splitRatio), range: TextSegment.splitRatioRange,
                             suffix: "%", percentage: true, defaultValue: TextSegment.defaultSplitRatio, detents: [0.5])
                EditorSlider(model: model, title: "栏间距", value: binding(id, \.splitGap), range: 0...240, decimals: 0,
                             defaultValue: TextSegment.defaultSplitGap)
            }
        }
        Picker("入场动画", selection: animationBinding(id, \.enterKind)) { animationOptions }.environment(\.colorScheme, .dark)
        EditorStepper(model: model, title: "入场时长", value: binding(id, \.enterDuration), range: 0...3, defaultValue: 0.4)
        Picker("出场动画", selection: animationBinding(id, \.exitKind)) { animationOptions }.environment(\.colorScheme, .dark)
        EditorStepper(model: model, title: "出场时长", value: binding(id, \.exitDuration), range: 0...3, defaultValue: 0.35)
        if value.enterDuration + value.exitDuration > value.duration {
            PanelNote("进出时长之和超过了本段时长，已按比例压缩。")
        }
        PanelSection("排版", expanded: $typographyExpanded) {
            Picker("字体", selection: familyBinding(id)) {
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
            EditorSlider(model: model, title: "行距", value: binding(id, \.lineHeight), range: 0.8...2.0, defaultValue: 1.30, detents: [1.0, 1.3])
            EditorSlider(model: model, title: "字间距", value: binding(id, \.tracking), range: -2...20, decimals: 1, defaultValue: 0, detents: [0])
            // 位置在画布比例的底板上拖（也可以直接在画布上拖文字）；靠近中线吸附。
            EditorRegion(model: model, title: "位置", shape: .point, aspect: model.edit.layout.ratio.value,
                         region: positionBinding(id)) { EditorRegion.positionReadout($0.origin) }
            EditorSlider(model: model, title: "文本框宽度", value: binding(id, \.maxWidth), range: TextSegment.maxWidthRange, suffix: "%", percentage: true, defaultValue: 0.8)
        }
        PanelSection("外观", expanded: $appearanceExpanded) {
            SwatchRow(title: "文字颜色", selection: paletteBinding(id, \.color))
            EditorFill(model: model, title: "不透明度", value: binding(id, \.opacity), range: 0...1, suffix: "%", percentage: true, defaultValue: 1)
            Toggle("文字背景", isOn: boolBinding(id, \.plate)).toggleStyle(StudioToggleStyle())
            if value.plate {
                SwatchRow(title: "背景色", selection: paletteBinding(id, \.plateColor))
                EditorFill(model: model, title: "背景不透明度", value: binding(id, \.plateOpacity), range: 0...1, suffix: "%", percentage: true, defaultValue: 0.55)
                EditorSlider(model: model, title: "内边距", value: binding(id, \.platePadding), range: 0...48, decimals: 0, defaultValue: 16)
                EditorSlider(model: model, title: "背景圆角", value: binding(id, \.plateRadius), range: 0...32, decimals: 0, defaultValue: 8)
            }
            Toggle("阴影", isOn: boolBinding(id, \.shadow)).toggleStyle(StudioToggleStyle())
            if value.shadow {
                EditorFill(model: model, title: "不透明度", value: binding(id, \.shadowOpacity), range: 0...1, suffix: "%", percentage: true, defaultValue: 0.45)
                EditorSlider(model: model, title: "模糊", value: binding(id, \.shadowBlur), range: 0...60, decimals: 0, defaultValue: 18)
                EditorSlider(model: model, title: "距离", value: binding(id, \.shadowOffset), range: -40...40, decimals: 0, defaultValue: 6, detents: [0])
            }
        }
        HStack(spacing: CaploMetrics.Spacing.s) {
            if let card {
                Button("复制卡片") { model.selectClip(card); model.duplicateSelection() }.buttonStyle(StudioButtonStyle(.secondary, size: .small))
                Button("删除卡片") { model.selectClip(card); model.deleteSelection() }.buttonStyle(StudioButtonStyle(.destructive, size: .small))
            } else {
                Button("复制这段") { model.select(.text(id)); model.duplicateSelection() }.buttonStyle(StudioButtonStyle(.secondary, size: .small))
                Button("删除这段") { model.select(.text(id)); model.deleteSelection() }.buttonStyle(StudioButtonStyle(.destructive, size: .small))
            }
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

    /// 点预设：已经选中一段（或一块卡片）就把预设套上去（文本、时间、版式都保留），否则新建一段。
    private func apply(_ preset: TextPreset) {
        guard let id = editingID, model.edit.text(id: id) != nil else {
            if let created = model.addText(preset: preset) { select(created) }
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
    private func selectFirstIfNeeded() {
        // 选中的是卡片时不抢：面板是因为卡片才切过来的。
        if model.selectedText == nil, model.selectedCard == nil, let first = model.edit.textList.first?.id { model.select(.text(first)) }
    }
    private func positionBinding(_ id: UUID) -> Binding<CGRect> {
        Binding(get: { CGRect(x: model.edit.text(id: id)?.x ?? 0.5, y: model.edit.text(id: id)?.y ?? 0.5, width: 0, height: 0) }, set: { rect in
            model.edit.updateText(id: id) { $0.x = rect.minX; $0.y = rect.minY }
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
            model.typeText { $0.updateText(id: id) { $0.text = String(value.prefix(TextSegment.textLimit)) } }
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
            model.commit { $0.updateText(id: id) { $0.layout = value } }
        })
    }
    private func paletteBinding(_ id: UUID, _ key: WritableKeyPath<TextSegment, TextSegment.Palette>) -> Binding<TextSegment.Palette> {
        Binding(get: { model.edit.text(id: id)?[keyPath: key] ?? .white }, set: { value in
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
                    .font(.system(size: 8 + min(1, max(0, (sample.size - 26) / 134)) * 9,
                                  weight: Font.Weight.from(sample.weight),
                                  design: sample.family.design))
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(preset.name).font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
            }
            .padding(.vertical, 5).padding(.horizontal, 4)
            .frame(height: 48)
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

/// 七格预设加一个自定义色。自定义格点开就是系统调色板（色轮 / 色卡 / 吸管都在里面）。
private struct SwatchRow: View {
    let title: String
    @Binding var selection: TextSegment.Palette
    /// 上次调过的自定义色：切到预设再切回来，不用重新调一遍。
    @State private var remembered = Color.white

    var body: some View {
        VStack(alignment: .leading, spacing: CaploMetrics.Spacing.xs) {
            Text(title).font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
            HStack(spacing: CaploMetrics.Spacing.xs) {
                ForEach(TextSegment.Palette.presets, id: \.self) { palette in
                    Button { selection = palette } label: {
                        Self.color(palette)
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(ring(selected: selection == palette, radius: 5))
                    }
                    .buttonStyle(.plain)
                    .help(palette.title)
                }
                // 自定义格：点开系统调色板（色轮 / 色卡 / 吸管都在里面）。
                // 原生色井比色板大一圈、形状也不一样，裁到 22 点只留中间那块纯色，和预设格并排才齐。
                // 没在用自定义色时盖一层色轮，一眼看出这格是"自己调"，不会和"白"那格撞脸。
                ColorPicker(selection: custom, supportsOpacity: false) { EmptyView() }
                    .labelsHidden()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay {
                        if !selection.isCustom {
                            AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(ring(selected: selection.isCustom, radius: 5).allowsHitTesting(false))
                    .help("自定义颜色")
                    .accessibilityLabel("自定义颜色")
            }
        }
    }

    private var custom: Binding<Color> {
        Binding(get: { selection.isCustom ? Self.color(selection) : remembered },
                set: { value in
                    remembered = value
                    let rgb = NSColor(value).usingColorSpace(.sRGB) ?? .white
                    selection = TextSegment.Palette(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
                })
    }

    private func ring(selected: Bool, radius: Double) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(selected ? CaploColor.accent : CaploColor.separator, lineWidth: selected ? 2 : 1)
    }

    private static func color(_ palette: TextSegment.Palette) -> Color {
        let rgb = palette.rgb
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
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

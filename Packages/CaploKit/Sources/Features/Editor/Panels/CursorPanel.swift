import AppKit
import SwiftUI
import CaploDesignSystem
import EditingCore
import RenderKit

/// 光标样式与运动参数；全部通过编辑历史提交并参与共享合成。
struct CursorPanel: View {
    let model: VideoEditorModel
    private var editable: Bool { model.entry.document.capture?.cursorEmbedded == false }
    /// 成片里不画光标：样式与运动参数这时没有意义，置灰；点击高亮照常（它有自己的开关）。
    private var hidden: Bool { model.edit.pointer?.cursorVisible == false }
    /// 旧版"片段设置"里单独隐藏过光标的片段数。那个面板已删除，这里给出提示和恢复入口。
    private var clipsHidingCursor: Int { model.edit.clips.filter(\.cursorHidden).count }
    @State private var category: CursorStyleGroup

    init(model: VideoEditorModel) {
        self.model = model
        _category = State(initialValue: CursorStyleGroup.containing(model.edit.pointer) ?? .arrow)
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !editable {
                PanelNote(String(localized: "这段素材是旧版本录的，原光标已录进视频，下面的样式与运动效果无法应用于它；点击高亮仍可调整。"))
            }
            VStack(alignment: .leading, spacing: CaploMetrics.Spacing.s) {
                Toggle(isOn: Binding(get: { hidden }, set: { hide in
                    model.commit { edit in
                        if edit.pointer == nil { var effects = PointerEffects(); effects.clicksVisible = false; edit.pointer = effects }
                        edit.pointer?.cursorVisible = !hide
                    }
                })) { SettingLabel(String(localized: "隐藏光标"), systemImage: "cursorarrow.slash") }
                    .toggleStyle(StudioToggleStyle())
                    .disabled(!editable)
                if hidden { PanelNote(String(localized: "成片里不画光标；点击高亮仍按下面的设置显示。")) }
                if clipsHidingCursor > 0 {
                    PanelNote(String(localized: "有 \(clipsHidingCursor) 个片段单独隐藏了光标（旧版片段设置留下的）。"))
                    Button("这些片段也显示光标") {
                        model.commit { edit in for index in edit.clips.indices { edit.clips[index].cursorHidden = false } }
                    }.buttonStyle(StudioButtonStyle(.secondary, size: .small))
                }
            }
            // 光标样式：上面按形状分类（箭头 / 指针 / 抓取 / 更多）切换预览，下面的格子是样式；录制始终单独保存真实光标轨迹，这里选的是回放时画成什么样。
            PanelSection(String(localized: "光标样式"), info: String(localized: "只替换箭头，其他光标形状保持原样")) {
                CursorCategoryBar(selection: $category)
                if category.styles.isEmpty {
                    PanelNote(String(localized: "此分组暂无样式。"))
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: CaploMetrics.Spacing.s), count: 4), spacing: CaploMetrics.Spacing.s) {
                        ForEach(category.styles) { theme in
                            CursorStyleTile(theme: theme, selected: theme.isSelected(in: model.edit.pointer)) {
                                model.commit { edit in
                                    if edit.pointer == nil { edit.pointer = .recommended }
                                    if var effects = edit.pointer { theme.apply(to: &effects); edit.pointer = effects }
                                }
                            }
                        }
                    }
                }
                // 允许小于 1×：最小值就是与录制时系统光标同大的倍率（按真实光标的点尺寸换算），并作为一个档位。
                EditorSlider(model: model, title: String(localized: "大小"), value: value(\.cursorScale), range: model.systemCursorScale...3, suffix: "×", defaultValue: 1, detents: [model.systemCursorScale, 1, 2])
                EditorDial(model: model, title: String(localized: "角度"), value: value(\.angle))
                EditorFill(model: model, title: String(localized: "随移动转向"), value: value(\.directionFollow), range: 0...1, suffix: "%", percentage: true, defaultValue: 0)
            }
            .disabled(!editable || hidden)
            Group {
                PanelSection(String(localized: "光标运动")) {
                    EditorFill(model: model, title: String(localized: "轨迹平滑"), value: value(\.smoothing), range: 0...2, defaultValue: 0)
                    EditorFill(model: model, title: String(localized: "点击弹跳"), value: value(\.bounce), range: 0...0.4, defaultValue: 0)
                    EditorSlider(model: model, title: String(localized: "弹跳速度"), value: value(\.bounceSpeed), range: 0.5...2, suffix: "×", defaultValue: 1, detents: [1])
                    EditorFill(model: model, title: String(localized: "摆动"), value: value(\.sway), range: 0...1, defaultValue: 0)
                    EditorFill(model: model, title: String(localized: "运动模糊"), value: value(\.motionBlur), range: 0...1, defaultValue: 0)
                    Toggle("静止时淡出", isOn: toggle(\.hideIdle)).toggleStyle(StudioToggleStyle())
                    Toggle("结尾回到起点", isOn: toggle(\.loop)).toggleStyle(StudioToggleStyle())
                }
            }
            .disabled(!editable || hidden)
            PanelSection(String(localized: "点击高亮")) {
                Toggle(isOn: toggle(\.clicksVisible)) { SettingLabel(String(localized: "点击高亮"), systemImage: "circle.circle") }.toggleStyle(StudioToggleStyle())
                Picker("点击样式", selection: choice(\.clickEffect)) {
                    Text("圆环").tag(PointerEffects.ClickEffect.ripple)
                    Text("光斑").tag(PointerEffects.ClickEffect.spotlight)
                    Text("双重波纹").tag(PointerEffects.ClickEffect.echo)
                }.environment(\.colorScheme, .dark)
                EditorSlider(model: model, title: String(localized: "高亮大小"), value: value(\.clickScale), range: 0.5...2, suffix: "×", defaultValue: 1, detents: [1])
                    .disabled(model.edit.pointer?.clicksVisible != true)
                ClickTintRow(effects: model.edit.pointer ?? PointerEffects()) { tint, custom in
                    model.commit { edit in
                        if edit.pointer == nil { edit.pointer = PointerEffects() }
                        edit.pointer?.tint = tint
                        edit.pointer?.customTint = custom
                    }
                }
                .disabled(model.edit.pointer?.clicksVisible != true)
            }
        }
    }

    private func choice<T>(_ key: WritableKeyPath<PointerEffects, T>) -> Binding<T> {
        Binding(get: { (model.edit.pointer ?? PointerEffects())[keyPath: key] }, set: { value in
            model.commit { edit in
                if edit.pointer == nil { edit.pointer = PointerEffects() }
                edit.pointer?[keyPath: key] = value
            }
        })
    }

    private func toggle(_ key: WritableKeyPath<PointerEffects, Bool>) -> Binding<Bool> {
        Binding(get: { model.edit.pointer?[keyPath: key] ?? false }, set: { value in model.commit { edit in
            if edit.pointer == nil {
                var effects = PointerEffects(); effects.clicksVisible = false
                edit.pointer = effects
            }
            edit.pointer?[keyPath: key] = value
        } })
    }

    private func value(_ key: WritableKeyPath<PointerEffects, Double>) -> Binding<Double> {
        Binding(get: { (model.edit.pointer ?? PointerEffects())[keyPath: key] }, set: { value in
            if model.edit.pointer == nil { model.edit.pointer = PointerEffects() }
            model.edit.pointer?[keyPath: key] = value
        })
    }
}

/// 样式格里的一项：要么是内置主题（现代），要么是用户绘制的样式（按 id）。
private struct CursorTheme: Identifiable {
    let id: String
    let title: String
    let style: PointerEffects.Style?
    let custom: String?
    static let modern = CursorTheme(id: "modern", title: String(localized: "现代"), style: .tahoe, custom: nil)
    init(id: String, title: String, style: PointerEffects.Style?, custom: String?) { self.id = id; self.title = title; self.style = style; self.custom = custom }
    init(_ style: CursorStyle) { self.init(id: style.id, title: style.title, style: nil, custom: style.id) }

    func isSelected(in effects: PointerEffects?) -> Bool {
        guard let effects else { return false }
        if let custom { return effects.cursorStyle == custom }
        return effects.cursorStyle == nil && effects.style == style
    }
    func apply(to effects: inout PointerEffects) {
        if let custom { effects.cursorStyle = custom } else { effects.cursorStyle = nil; if let style { effects.style = style } }
    }
    /// 预览由后台渲染，第一次可能为空（格子先显示空底板），渲染完成后面板自动刷新。
    @MainActor var preview: NSImage? { custom.map { CursorPreviews.shared.image(customStyle: $0) } ?? style.flatMap { CursorPreviews.shared.image(style: $0, shape: .arrow) } }
}

/// 样式分组（像 FocuSee）：分段条选组，组内是样式。箭头组以内置"现代"开头，其余四组各十款是用户绘制的样式。
private enum CursorStyleGroup: CaseIterable {
    case arrow, pointer, minimal, circle
    var symbol: String {
        switch self {
        case .arrow: "cursorarrow"
        case .pointer: "hand.point.up.left"
        case .minimal: "arrow.up.left"
        case .circle: "circle"
        }
    }
    var title: String {
        switch self {
        case .arrow: String(localized: "箭头")
        case .pointer: String(localized: "指针")
        case .minimal: String(localized: "简约")
        case .circle: String(localized: "圆圈")
        }
    }
    private var catalogGroup: CursorStyle.Group {
        switch self { case .arrow: .arrow; case .pointer: .pointer; case .minimal: .minimal; case .circle: .circle }
    }
    var styles: [CursorTheme] {
        let drawn = CursorStyle.styles(in: catalogGroup).map(CursorTheme.init)
        return self == .arrow ? [.modern] + drawn : drawn
    }
    static func containing(_ effects: PointerEffects?) -> CursorStyleGroup? {
        guard let effects else { return nil }
        if let id = effects.cursorStyle, let style = CursorStyle.style(id: id) {
            return allCases.first { $0.catalogGroup == style.group }
        }
        return .arrow
    }
}

/// 分段条：整行圆角底板，选中段是更亮的圆角块，图标白色；其余图标次级色。
private struct CursorCategoryBar: View {
    @Binding var selection: CursorStyleGroup
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CursorStyleGroup.allCases, id: \.self) { category in
                Button { withAnimation(.easeOut(duration: CaploMotion.hover)) { selection = category } } label: {
                    Image(systemName: category.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selection == category ? CaploColor.textPrimary : CaploColor.textSecondary)
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background {
                            if selection == category {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(CaploColor.surfaceOpaqueRaised)
                                    .matchedGeometryEffect(id: "segment", in: highlight)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(category.title)
                .accessibilityAddTraits(selection == category ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(CaploColor.surfaceRaised.opacity(0.8)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CaploColor.separator))
    }
}

/// 样式格：宽扁圆角块，中间是该样式在当前分类下的形状；选中用强调色描边加软底。
private struct CursorStyleTile: View {
    let theme: CursorTheme
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? CaploColor.accentSoft : CaploColor.surfaceRaised.opacity(hovered ? 1 : 0.8))
                if let image = theme.preview {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 26, height: 26)
                }
            }
            .aspectRatio(1.7, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? CaploColor.accent : CaploColor.separator, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .hoverTip(theme.title)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 点击高亮颜色：三个预设色块加一个自定义格，自定义格点开系统调色板（色轮 / 色卡 / 吸管）。
/// 与文字层的颜色行同一套外观；没在用自定义色时自定义格盖一层色轮，一眼看出是"自己调"。
private struct ClickTintRow: View {
    let effects: PointerEffects
    let apply: (PointerEffects.Tint, String?) -> Void
    /// 上次调过的自定义色：切到预设再切回来，不用重新调。
    @State private var remembered = Color(red: 1, green: 0.42, blue: 0.42)

    private static let presets: [(PointerEffects.Tint, String)] = [(.violet, String(localized: "紫色")), (.blue, String(localized: "蓝色")), (.yellow, String(localized: "黄色"))]
    private var isCustom: Bool { effects.customTint != nil }

    var body: some View {
        HStack(spacing: CaploMetrics.Spacing.xs) {
            Text("颜色").font(CaploFont.body).foregroundStyle(CaploColor.textPrimary)
            Spacer()
            ForEach(Self.presets, id: \.0) { tint, name in
                Button { apply(tint, nil) } label: {
                    Self.color(for: tint)
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(ring(selected: !isCustom && effects.tint == tint))
                }
                .buttonStyle(.plain)
                .help(name)
                .accessibilityLabel(name)
            }
            ColorPicker(selection: custom, supportsOpacity: false) { EmptyView() }
                .labelsHidden()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    if !isCustom {
                        AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .allowsHitTesting(false)
                    }
                }
                .overlay(ring(selected: isCustom).allowsHitTesting(false))
                .help("自定义颜色")
                .accessibilityLabel("自定义颜色")
        }
    }

    private var custom: Binding<Color> {
        Binding(get: {
            guard isCustom else { return remembered }
            let rgb = effects.tintRGB
            return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        }, set: { value in
            remembered = value
            let rgb = NSColor(value).usingColorSpace(.sRGB) ?? .white
            apply(effects.tint, TextSegment.Palette(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent).rawValue)
        })
    }

    private func ring(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(selected ? CaploColor.accent : CaploColor.separator, lineWidth: selected ? 2 : 1)
    }

    private static func color(for tint: PointerEffects.Tint) -> Color {
        var preset = PointerEffects()
        preset.tint = tint
        let rgb = preset.tintRGB
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

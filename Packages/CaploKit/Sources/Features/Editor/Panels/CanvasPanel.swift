import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CaploDesignSystem
import EditingCore
import ProjectKit
import RenderKit

/// 布局：比例（常用 chips + 平台下拉）、背景（渐变 / 纯色 / 图片）、留白、圆角、阴影（可调不透明度、柔和度、距离）与预设。
struct CanvasPanel: View {
    let model: VideoEditorModel
    private enum BackgroundKind: String, CaseIterable { case gradient = "渐变", solid = "纯色", image = "图片" }
    /// 背景分类只在面板创建时按当前工程推断一次；之后完全由用户点选决定。
    /// （原来挂在最后一个分区的 `onAppear` 上，图片页把它挤出可视区再滚回来就会重新推断成"图片"，渐变 / 纯色怎么点都切不过去。）
    @State private var kind: BackgroundKind

    init(model: VideoEditorModel) {
        self.model = model
        let layout = model.edit.layout
        _kind = State(initialValue: layout.backgroundImage != nil ? .image : layout.background.isSolid ? .solid : .gradient)
    }
    @State private var presets = CanvasPresetStore.shared
    @State private var namingPreset = false
    @State private var presetName = ""
    /// 最近一次从平台下拉选中的格式；只用于显示，工程里只保存比例。
    @State private var platform: String?
    @State private var library = BackgroundLibrary.shared
    /// 「自定义」那一格当前的颜色。种子用 Cap 新建渐变的默认色，改过之后这一整场编辑都记着。
    @State private var customGradient = CanvasBackground(start: (red: 0.278, green: 0.522, blue: 1),
                                                        end: (red: 1, green: 0.278, blue: 0.400))
    /// 最近一次从图库选中的壁纸键；工程里只保存复制进去的图片路径。
    @State private var chosenBackdrop: String?
    @State private var importingBackdrop: String?
    @State private var series: WallpaperSeries = .echoes

    var body: some View {
        PanelSection("画面比例") {
            ChipGroup(CanvasRatio.common, selection: Binding(get: { model.edit.layout.ratio }, set: { ratio in model.commit { $0.layout.ratio = ratio } })) { $0.rawValue }
            SelectField(value: currentPlatform?.title, placeholder: "按平台选择…", accessibilityName: "平台比例", sections: platformSections)
            Text(outputCaption).font(CaploFont.caption).monospacedDigit().foregroundStyle(CaploColor.textTertiary)
            // 开：镜头推近只放大录屏框里的内容，留白与背景不动；关：整个画面一起推近（像 FocuSee）。
            Toggle(isOn: Binding(get: { model.edit.layout.fixedFocusFrame }, set: { value in model.commit { $0.layout.fixedFocusFrame = value } })) {
                SettingLabel("固定聚焦区域", systemImage: "rectangle.dashed")
            }.toggleStyle(StudioToggleStyle())
        }
        PanelSection("背景") {
            ChipGroup(BackgroundKind.allCases, selection: $kind) { $0.rawValue }
            switch kind {
            case .gradient:
                // 最后一格是自定义渐变：种子取 Cap 新建渐变时的那一对色，选中后下面露出调色卡。
                BackgroundSwatches(options: CanvasBackground.gradients + [customGradient],
                                   selected: model.edit.layout.backgroundImage == nil ? model.edit.layout.background : nil) { value in
                    if value.isCustom { customGradient = value }
                    model.commit { $0.layout.background = value; $0.layout.backgroundImage = nil }
                }
                if model.edit.layout.backgroundImage == nil, model.edit.layout.background.isCustom, !model.edit.layout.background.isSolid {
                    GradientEnds(background: Binding(get: { model.edit.layout.background },
                                                     set: { value in customGradient = value; model.commit { $0.layout.background = value } }))
                }
            case .solid:
                BackgroundSwatches(options: CanvasBackground.solids, selected: model.edit.layout.backgroundImage == nil ? model.edit.layout.background : nil) { value in
                    model.commit { $0.layout.background = value; $0.layout.backgroundImage = nil }
                }
            case .image:
                imageControls
            }
            // 只有真的在用图片时才给模糊：渐变与纯色糊了还是原样，摆个滑块出来纯属误导。
            if model.edit.layout.backgroundImage != nil {
                EditorSlider(model: model, title: "背景模糊", value: Binding(get: { model.edit.layout.backgroundBlur },
                                                                        set: { model.edit.layout.backgroundBlur = $0 }),
                             range: 0...100, decimals: 0, defaultValue: 0)
            }
        }
        PanelSection("样式") {
            EditorSlider(model: model, title: "边距", value: Binding(get: { model.edit.layout.padding }, set: { model.edit.layout.padding = $0 }), range: 0...120, decimals: 0, defaultValue: 0)
            EditorSlider(model: model, title: "圆角", value: Binding(get: { model.edit.layout.cornerRadius }, set: { model.edit.layout.cornerRadius = $0 }), range: 0...40, decimals: 0, defaultValue: 12)
        }
        PanelSection("阴影") {
            Toggle(isOn: Binding(get: { model.edit.layout.shadow }, set: { value in model.commit { $0.layout.shadow = value } })) {
                SettingLabel("阴影", systemImage: "square.3.layers.3d")
            }.toggleStyle(StudioToggleStyle())
            if model.edit.layout.shadow {
                EditorSlider(model: model, title: "不透明度", value: Binding(get: { model.edit.layout.shadowOpacity }, set: { model.edit.layout.shadowOpacity = $0 }), range: 0...1, suffix: "%", percentage: true, defaultValue: CanvasLayout.defaultShadowOpacity)
                EditorSlider(model: model, title: "模糊", value: Binding(get: { model.edit.layout.shadowBlur }, set: { model.edit.layout.shadowBlur = $0 }), range: 0...60, decimals: 0, defaultValue: CanvasLayout.defaultShadowBlur)
                EditorSlider(model: model, title: "距离", value: Binding(get: { model.edit.layout.shadowOffset }, set: { model.edit.layout.shadowOffset = $0 }), range: -40...40, decimals: 0, defaultValue: CanvasLayout.defaultShadowOffset, detents: [0])
            }
        }
        PanelSection("预设", info: "预设保存比例、背景、边距、圆角、阴影与裁切；自定义图片属于工程，不进预设。") {
            // 预设用下拉选择：当前布局与哪个预设一致就显示哪个，否则显示占位；没有预设时下拉禁用并给一行说明。
            SelectField(value: matchingPreset?.name, placeholder: presets.presets.isEmpty ? "还没有预设" : "选择预设…", accessibilityName: "布局预设", sections: [
                SelectField.Section(items: presets.presets.map { preset in
                    SelectField.Item(id: preset.id.uuidString, title: preset.name, checked: presetMatches(preset)) { apply(preset) }
                }),
            ])
            .disabled(presets.presets.isEmpty)
            if presets.presets.isEmpty {
                PanelNote("调好布局后保存为预设，以后一键套用到其他工程。")
            }
            HStack(spacing: CaploMetrics.Spacing.s) {
                Button("保存为预设…") { presetName = ""; namingPreset = true }
                    .buttonStyle(StudioButtonStyle(.secondary, size: .small))
                    .popover(isPresented: $namingPreset, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: CaploMetrics.Spacing.m) {
                            Text("预设名称").font(CaploFont.panelTitle).foregroundStyle(CaploColor.textPrimary)
                            TextField("例如：产品演示", text: $presetName).textFieldStyle(.roundedBorder)
                                .environment(\.colorScheme, .dark)
                                .onSubmit { presets.save(name: presetName, layout: model.edit.layout); namingPreset = false }
                            HStack {
                                Spacer()
                                Button("取消") { namingPreset = false }.buttonStyle(StudioButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
                                Button("保存") { presets.save(name: presetName, layout: model.edit.layout); namingPreset = false }
                                    .buttonStyle(StudioButtonStyle(.primary)).keyboardShortcut(.defaultAction)
                            }
                        }.padding(CaploMetrics.Spacing.l).frame(width: 280).background(CaploMaterialBackground(.floating))
                    }
                if let matchingPreset {
                    Button("删除预设") { presets.remove(matchingPreset) }.buttonStyle(StudioButtonStyle(.quiet, size: .small))
                        .hoverTip("删除「\(matchingPreset.name)」")
                }
                Button("重置布局") { model.commit { $0.layout = CanvasLayout() } }.buttonStyle(StudioButtonStyle(.quiet, size: .small))
            }
        }
        .onAppear { library.scanSystemWallpapers() }
    }

    /// 下拉显示的平台：优先最近选中且比例仍相符的；常用比例没有平台含义则留空；4:5、6:7 只经平台进入，显示对应的第一个平台。
    private var currentPlatform: PlatformFormat? {
        let ratio = model.edit.layout.ratio
        if let platform, let format = PlatformFormat.format(id: platform), format.ratio == ratio { return format }
        return CanvasRatio.common.contains(ratio) ? nil : PlatformFormat.first(matching: ratio)
    }

    /// 平台按横 / 竖 / 方分组，不分地区；组内顺序即 `PlatformFormat.all` 的热度顺序。
    private var platformSections: [SelectField.Section] {
        CanvasRatio.Orientation.allCases.map { orientation in
            SelectField.Section(orientation.rawValue, items: PlatformFormat.formats(in: orientation).map { format in
                SelectField.Item(id: format.id, title: format.title, checked: currentPlatform?.id == format.id) { choosePlatform(format) }
            })
        }
    }

    private func choosePlatform(_ format: PlatformFormat) {
        platform = format.id
        if model.edit.layout.ratio != format.ratio { model.commit { $0.layout.ratio = format.ratio } }
    }

    private var outputCaption: String {
        let ratio = model.edit.layout.ratio
        let hd = ratio.outputSize(shortEdge: 1080), uhd = ratio.outputSize(shortEdge: 2160)
        return "导出 1080p 为 \(hd.width)×\(hd.height)，4K 为 \(uhd.width)×\(uhd.height)"
    }

    private func presetMatches(_ preset: CanvasPreset) -> Bool {
        var current = model.edit.layout; current.backgroundImage = nil
        return current == preset.layout
    }
    private var matchingPreset: CanvasPreset? { presets.presets.first(where: presetMatches) }
    /// 套用预设：保留工程自己的背景图片。
    private func apply(_ preset: CanvasPreset) {
        model.commit { edit in
            var layout = preset.layout
            layout.backgroundImage = edit.layout.backgroundImage
            edit.layout = layout
        }
    }

    @ViewBuilder private var imageControls: some View {
        if let path = model.edit.layout.backgroundImage, let file = try? ProjectStorage.backgroundURL(path, in: model.entry.url) {
            // 预览走缩略图缓存：原来在 body 里 `NSImage(contentsOf:)` 每次重绘都解整张 5K 图，是面板一动就卡的根源之一。
            ZStack {
                RoundedRectangle(cornerRadius: CaploMetrics.Radius.control).fill(CaploColor.surfaceRaised)
                if let image = library.preview(forProjectImage: file) { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            }
            .frame(height: 96).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control).strokeBorder(CaploColor.separator))
            HStack(spacing: CaploMetrics.Spacing.s) {
                Button("更换图片…", action: importImage).buttonStyle(StudioButtonStyle(.secondary, size: .small))
                Button("移除图片") { chosenBackdrop = nil; model.commit { $0.layout.backgroundImage = nil } }.buttonStyle(StudioButtonStyle(.quiet, size: .small))
            }
        } else {
            PanelNote("图片会按填满画面裁切，并随工程一起保存；导出与预览一致。")
            Button { importImage() } label: { Label("导入图片…", systemImage: "photo.badge.plus") }.buttonStyle(StudioButtonStyle(.secondary))
        }
        Text("内置壁纸").font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
        ChipGroup(WallpaperSeries.allCases, selection: $series) { $0.title }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: CaploMetrics.Spacing.xs + 1), count: 4), spacing: CaploMetrics.Spacing.xs + 1) {
            ForEach(WallpaperCatalog.wallpapers(in: series)) { wallpaper in
                BackdropTile(name: wallpaper.title, image: library.thumbnail(for: wallpaper), selected: isChosen("bundled." + wallpaper.id), busy: importingBackdrop == "bundled." + wallpaper.id) {
                    choose("bundled." + wallpaper.id) { project in try BackgroundLibrary.importBundled(wallpaper, into: project) }
                }
            }
        }
        if !library.system.isEmpty {
            Text("本机壁纸").font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: CaploMetrics.Spacing.xs + 1), count: 4), spacing: CaploMetrics.Spacing.xs + 1) {
                ForEach(library.system) { wallpaper in
                    BackdropTile(name: wallpaper.name, image: library.thumbnail(for: wallpaper), selected: isChosen("system." + wallpaper.id), busy: importingBackdrop == "system." + wallpaper.id) {
                        let url = wallpaper.url
                        choose("system." + wallpaper.id) { project in try BackgroundLibrary.importSystemWallpaper(url, into: project) }
                    }
                }
            }
        }
    }

    private func isChosen(_ key: String) -> Bool { chosenBackdrop == key && model.edit.layout.backgroundImage != nil }

    /// 壁纸在后台转成工程内图片，完成后一次提交；期间该格显示转圈，重复点击忽略。
    private func choose(_ key: String, _ produce: @escaping @Sendable (URL) throws -> String) {
        guard importingBackdrop == nil else { return }
        importingBackdrop = key
        let project = model.entry.url
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { Result { try produce(project) } }.value
            importingBackdrop = nil
            switch outcome {
            case .success(let path): chosenBackdrop = key; model.commit { $0.layout.backgroundImage = path }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
    }

    private func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let path = try ProjectStorage.importBackground(from: url, into: model.entry.url)
            model.commit { $0.layout.backgroundImage = path }
        } catch { model.error = error.localizedDescription }
    }
}

/// 壁纸格：16:9 缩略图，未生成时是空底板，选中环与色板同款（外圆角同心、1.5 点）。
struct BackdropTile: View {
    let name: String
    let image: NSImage?
    let selected: Bool
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: CaploMetrics.Radius.control).fill(CaploColor.surfaceRaised)
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                if busy { ProgressView().controlSize(.small) }
            }
            .aspectRatio(16.0 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control).strokeBorder(CaploColor.separator))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: CaploMetrics.Radius.control + 2, style: .continuous)
                        .strokeBorder(CaploColor.accent, lineWidth: 1.5)
                        .padding(-2)
                }
            }
        }
        .buttonStyle(.plain)
        .hoverTip(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 色板：数值来自 `CanvasBackground.colors`，与渲染器一致。最后一格是「自定义」，选中它下面会露出起点 / 终点两个色井。
struct BackgroundSwatches: View {
    let options: [CanvasBackground]
    let selected: CanvasBackground?
    let choose: (CanvasBackground) -> Void
    var body: some View {
        SwatchGrid(options.map { value in
            Swatch(id: value.rawValue, name: value.isCustom ? "自定义" : value.rawValue, colors: [
                Color(red: value.colors.start.red, green: value.colors.start.green, blue: value.colors.start.blue),
                Color(red: value.colors.end.red, green: value.colors.end.green, blue: value.colors.end.blue),
            ])
        }, selection: Binding(get: { selected?.rawValue }, set: { _ in }), columns: 8) { swatch in
            choose(CanvasBackground(rawValue: swatch.id))
        }
    }
}

/// 渐变调色卡：起点与终点两个色井，改哪个都立刻写回自定义渐变。
struct GradientEnds: View {
    @Binding var background: CanvasBackground
    var body: some View {
        HStack(spacing: CaploMetrics.Spacing.m) {
            well("起点", \.start)
            well("终点", \.end)
            Spacer(minLength: 0)
            Text(background.rawValue).font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
        }
    }

    private func well(_ title: String, _ key: KeyPath<(start: (red: Double, green: Double, blue: Double), end: (red: Double, green: Double, blue: Double)), (red: Double, green: Double, blue: Double)>) -> some View {
        let value = background.colors[keyPath: key]
        return HStack(spacing: CaploMetrics.Spacing.xs) {
            Text(title).font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
            ColorPicker(selection: Binding<Color>(get: { Color(red: value.red, green: value.green, blue: value.blue) },
                                          set: { picked in
                                              let rgb = NSColor(picked).usingColorSpace(.sRGB) ?? .white
                                              let next = (red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent))
                                              let ends = background.colors
                                              background = CanvasBackground(start: key == \.start ? next : ends.start,
                                                                            end: key == \.end ? next : ends.end)
                                          }), supportsOpacity: false) { EmptyView() }
                .labelsHidden()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(CaploColor.separator))
                .accessibilityLabel(title)
        }
    }
}

/// 简单流式布局，用于预设 chips 换行。
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x = 0.0, y = 0.0, rowHeight = 0.0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight = 0.0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}

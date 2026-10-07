import SwiftUI
import AppKit
import CaploDesignSystem
import EditingCore
import RenderKit

/// 编辑器外壳：顶栏、左侧图标栏、属性面板、画布井与时间线。工作区按卡片排布：面板、画布、时间线
/// 各是一块 12 点圆角的中性透光区域，彼此留 8 点窗口材质。
/// 项目图标打开独立管理窗口，编辑会话继续保留；分组切换只换面板内容，不重建画布与时间线。
struct VideoEditorView: View {
    static let panels: [RailItem] = [
        RailItem(id: "布局", title: String(localized: "布局"), symbol: "rectangle.on.rectangle", shortcut: "1"),
        RailItem(id: "光标", title: String(localized: "光标"), symbol: "cursorarrow", shortcut: "2"),
        RailItem(id: "聚焦", title: String(localized: "聚焦"), symbol: "viewfinder", shortcut: "3"),
        RailItem(id: "人像", title: String(localized: "人像"), symbol: "person.crop.square", shortcut: "4"),
        RailItem(id: "音频", title: String(localized: "音频"), symbol: "waveform", shortcut: "5"),
        RailItem(id: "裁剪", title: String(localized: "裁剪"), symbol: "crop", shortcut: "6"),
        // "片段设置"已删除（2026-10-06）：声音块的单块音量并进"音频"，片段级光标隐藏由"光标"面板的全局开关代替。
        RailItem(id: "遮罩", title: String(localized: "遮罩"), symbol: "rectangle.dashed", shortcut: "7"),
        RailItem(id: "文字", title: String(localized: "文字"), symbol: "text.alignleft", shortcut: "8"),
        RailItem(id: "字幕", title: String(localized: "字幕"), symbol: "captions.bubble", shortcut: "9"),
    ]

    @State private var model: VideoEditorModel
    @State private var tab = "布局"
    @State private var viewport = TimelineViewport()
    @State private var suppressOverlapPrompt = false
    let back: () -> Void
    let previewTime: Double

    init(model: VideoEditorModel, previewTime: Double = 0, initialTab: String = "布局", back: @escaping () -> Void) {
        _model = State(initialValue: model); _tab = State(initialValue: initialTab)
        self.back = back; self.previewTime = previewTime
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorTopBar(model: model, back: back)
            if let error = model.error {
                HStack(spacing: CaploMetrics.Spacing.s) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(CaploColor.warning)
                    Text(error).font(CaploFont.caption).textSelection(.enabled)
                    Spacer()
                    if model.saveFailed { Button("重试保存") { model.retrySave() }.buttonStyle(StudioButtonStyle(.secondary, size: .small)) }
                    Button("关闭提示") { model.error = nil }.buttonStyle(StudioButtonStyle(.quiet, size: .small))
                }
                .padding(.horizontal, CaploMetrics.Spacing.l).frame(height: 32)
                .background(CaploColor.warning.opacity(0.1))
            }
            HStack(spacing: CaploMetrics.Spacing.s) {
                IconRail(Self.panels, selection: $tab, disabled: disabledPanels)
                PanelContainer(panelTitle) {
                    panelContent
                    if let warning = model.entry.document.warning {
                        Text(warning).font(CaploFont.caption).foregroundStyle(CaploColor.warning)
                    }
                }
                .disabled(!model.ready)
                .studioCard()
                EditorWorkspace(model: model, viewport: viewport) { model.requestAddFocus(); tab = "聚焦" }.frame(maxWidth: .infinity)
            }
            .padding([.top, .trailing, .bottom], CaploMetrics.Spacing.s)
        }
        .background(CaploMaterialBackground(.window))
        .foregroundStyle(CaploColor.textPrimary)
        .tint(CaploColor.accent)
        .task {
            await model.open()
            // 打开即"缩放到适合窗口"：整条时间线正好铺满视口，与工具栏那个按钮一致。
            viewport.fit(duration: model.edit.duration)
            // 预热光标面板会先显示的那组样式预览（后台低优先级），切到"光标与点击"时直接命中缓存；其余组按需加载。
            CursorPreviews.shared.warmUp(group: model.edit.pointer?.cursorStyle.flatMap(CursorStyle.style(id:))?.group ?? .arrow)
            if previewTime > 0 {
                model.seek(previewTime)
                if tab == "布局" { if let first = model.edit.focuses.first?.id { model.select(.focus(first)) }; tab = "聚焦" }
            }
        }
        .onChange(of: model.edit) { model.previewChanged() }
        .onChange(of: model.selectedMedia) { if let role = model.selectedMedia { tab = role == .camera ? "人像" : "音频" } }
        .onChange(of: model.selectedFocus) { if model.selectedFocus != nil { tab = "聚焦" } }
        .onChange(of: model.selectedMask) { if model.selectedMask != nil { tab = "遮罩" } }
        .onChange(of: model.selectedText) { if model.selectedText != nil { tab = "文字" } }
        // 卡片的字与背景在文字面板里改。
        .onChange(of: model.selectedClip) { if model.selectedCard != nil { tab = "文字" } }
        .onChange(of: model.selectedCaption) { if model.selectedCaption != nil { tab = "字幕" } }
        // 导出窗口：格式、分辨率、帧率、画质、声音。
        .sheet(isPresented: Binding(get: { model.showingExport }, set: { model.showingExport = $0 })) { ExportSheet(model: model) }
        // 要添加的时间段已经有镜头：问一下，可以勾"不再提示"。
        .sheet(item: Binding(get: { model.pendingFocus }, set: { if $0 == nil { model.cancelPendingFocus() } })) { pending in
            StudioConfirmSheet(title: String(localized: "这段时间已有镜头"),
                               message: String(localized: "\(TimelineTime.code(pending.start)) 到 \(TimelineTime.code(pending.start + pending.duration)) 之间已经有一个镜头。再添加一个的话，两个镜头会叠在一起，后添加的在上。"),
                               confirmTitle: String(localized: "仍然添加"), suppression: $suppressOverlapPrompt,
                               confirm: { model.confirmPendingFocus(suppressFurtherPrompts: suppressOverlapPrompt) },
                               cancel: { model.cancelPendingFocus() })
        }
        // 摄像头片段被删光（或本就没录）时"人像"不可选；正停在人像面板上就退回布局。
        .onChange(of: model.hasCameraMedia, initial: true) { if !model.hasCameraMedia, tab == "人像" { tab = "布局" } }
    }

    /// 工具栏里不可选的面板：没有人像素材时"人像"灰掉，没有画面时叠加层面板灰掉。
    private var disabledPanels: Set<String> {
        var result: Set<String> = []
        if !model.hasCameraMedia { result.insert("人像") }
        if model.edit.clips.isEmpty { result.insert("遮罩"); result.insert("文字"); result.insert("字幕") }
        return result
    }

    private var panelTitle: String {
        switch tab {
        case "布局": String(localized: "画面布局")
        case "光标": String(localized: "光标与点击")
        case "聚焦": String(localized: "镜头聚焦")
        case "人像": String(localized: "摄像头画中画")
        case "音频": String(localized: "声音混合")
        case "裁剪": String(localized: "裁剪画面")
        case "遮罩": String(localized: "画面遮罩")
        case "文字": String(localized: "文字层")
        case "字幕": String(localized: "字幕")
        default: tab
        }
    }

    @ViewBuilder private var panelContent: some View {
        switch tab {
        case "布局": CanvasPanel(model: model)
        case "光标": CursorPanel(model: model)
        case "聚焦": FocusPanel(model: model)
        case "人像": CameraPanel(model: model)
        case "裁剪": CropPanel(model: model)
        case "遮罩": MaskPanel(model: model)
        case "文字": TextPanel(model: model)
        case "字幕": CaptionPanel(model: model)
        default: AudioPanel(model: model)
        }
    }
}

/// 顶栏：左侧为原生红黄绿预留位、项目中心与项目名；右侧导出（格式、分辨率等在导出窗口里选）。撤销重做在时间线工具栏。
private struct EditorTopBar: View {
    let model: VideoEditorModel
    let back: () -> Void

    var body: some View {
        HStack(spacing: CaploMetrics.Spacing.m) {
            Spacer().frame(width: CaploMetrics.trafficLightsInset - CaploMetrics.Spacing.l)
            Button { model.pause(); back() } label: { Image(systemName: "square.grid.2x2") }
                .buttonStyle(StudioIconButtonStyle()).help("项目中心 \(ShortcutStore.shared.display(.projectLibrary))").accessibilityLabel("项目中心")
            VStack(alignment: .leading, spacing: 1) {
                Text(model.entry.document.name).font(CaploFont.bodyMedium).foregroundStyle(CaploColor.textPrimary).lineLimit(1)
                Text(model.saveStatus).font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
            }
            Spacer()
            if model.exporting {
                ProgressView(value: model.progress).frame(width: 120)
                Text("\(Int(model.progress * 100))%").font(CaploFont.value).foregroundStyle(CaploColor.textSecondary)
                Button("取消") { model.cancelExport() }.buttonStyle(StudioButtonStyle(.quiet))
            } else {
                Button { model.export() } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    .buttonStyle(StudioButtonStyle(.primary, size: .large)).shortcut(.export)
                    .disabled(!model.ready || (model.edit.duration <= 0) || model.loading)
            }
        }
        .padding(.horizontal, CaploMetrics.Spacing.l)
        .frame(height: CaploMetrics.titleBarHeight)
        .background(CaploMaterialBackground(.panel))
    }
}

func timecode(_ value: Double) -> String {
    let value = value.isFinite ? max(0, value) : 0
    return String(format: "%02d:%02d.%01d", Int(value) / 60, Int(value) % 60, Int(value * 10) % 10)
}

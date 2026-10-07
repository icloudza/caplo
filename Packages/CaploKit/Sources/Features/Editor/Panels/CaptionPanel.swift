import SwiftUI
import UniformTypeIdentifiers
import CaploDesignSystem
import EditingCore
import ExportKit

/// 字幕：本机转写、样式、逐句编辑与 SRT / VTT 导入导出。
///
/// 转写全程在本机完成，音频不会离开这台电脑。中文的词级时间戳普遍很粗，
/// 所以「按字均分」默认打开——逐词点亮宁可均匀也不要一顿一顿。
struct CaptionPanel: View {
    let model: VideoEditorModel
    @State private var styleExpanded: Bool
    @State private var timingExpanded: Bool
    private static let styleKey = "editor.caption.styleExpanded"
    private static let timingKey = "editor.caption.timingExpanded"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: VideoEditorModel) {
        self.model = model
        _styleExpanded = State(initialValue: UserDefaults.standard.object(forKey: Self.styleKey) as? Bool ?? true)
        _timingExpanded = State(initialValue: UserDefaults.standard.object(forKey: Self.timingKey) as? Bool ?? false)
    }

    var body: some View {
        PanelSection("转写", info: "本机转写，音频不上传；改过的句子不会被覆盖") {
            if let progress = model.transcription {
                ProgressView(value: progress.progress).progressViewStyle(.linear)
                Text(progress.message).font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
                Button("取消") { model.cancelTranscription() }.buttonStyle(StudioButtonStyle(.secondary))
            } else if !model.hasTranscribableAudio {
                PanelNote("这个工程没有录到声音。可以导入现成的 SRT / VTT 字幕。")
            } else {
                let sources = TranscriptionSource.allCases.filter { ProjectTranscription.hasAudio(model.entry.document, source: $0) }
                if sources.count > 1 {
                    Picker("声音来源", selection: sourceBinding) {
                        ForEach(sources) { Text($0.title).tag($0) }
                    }.environment(\.colorScheme, .dark)
                }
                Picker("语言", selection: localeBinding) {
                    Text("中文（普通话）").tag("zh-CN")
                    Text("英语（美国）").tag("en-US")
                    Text("日语").tag("ja-JP")
                    Text("跟随系统（\(model.captionLocale.localizedString(forLanguageCode: model.captionLocale.language.languageCode?.identifier ?? "zh") ?? "中文")）").tag("system")
                }.environment(\.colorScheme, .dark)
                Button(model.edit.captionList.isEmpty ? "开始转写" : "重新转写") { model.transcribe() }
                    .buttonStyle(StudioButtonStyle(.primary))
            }
            HStack(spacing: CaploMetrics.Spacing.s) {
                Button("导入字幕…") { importFile() }.buttonStyle(StudioButtonStyle(.secondary, size: .small))
                Button("导出 SRT…") { exportFile(vtt: false) }.buttonStyle(StudioButtonStyle(.secondary, size: .small))
                    .disabled(model.edit.captionList.isEmpty)
            }
        }

        if !model.edit.captionList.isEmpty {
            PanelSection("样式", expanded: $styleExpanded) {
                Picker("字体", selection: styleBinding(\.family)) {
                    Text("系统").tag(TextSegment.Family.system)
                    Text("无衬线").tag(TextSegment.Family.sans)
                    Text("衬线").tag(TextSegment.Family.serif)
                    Text("圆体").tag(TextSegment.Family.rounded)
                    Text("等宽").tag(TextSegment.Family.mono)
                }.environment(\.colorScheme, .dark)
                EditorSlider(model: model, title: "字号", value: numberBinding(\.size), range: 20...120, decimals: 0, defaultValue: 46)
                EditorSlider(model: model, title: "字重", value: numberBinding(\.weight), range: TextSegment.weightRange, decimals: 0, defaultValue: 600, detents: [400, 600, 700])
                EditorFill(model: model, title: "垂直位置", value: numberBinding(\.y), range: 0.5...0.98, suffix: "%", percentage: true, defaultValue: 0.86)
                EditorFill(model: model, title: "最大宽度", value: numberBinding(\.maxWidth), range: 0.3...1, suffix: "%", percentage: true, defaultValue: 0.72)
                Toggle("文字背景", isOn: boolBinding(\.plate)).toggleStyle(StudioToggleStyle())
                if model.edit.captionStyleOrDefault.plate {
                    EditorFill(model: model, title: "背景不透明度", value: numberBinding(\.plateOpacity), range: 0...1, suffix: "%", percentage: true, defaultValue: 0.55)
                }
                Picker("逐词高亮", selection: highlightBinding) {
                    ForEach(CaptionStyle.Highlight.allCases, id: \.self) { Text($0.title).tag($0) }
                }.environment(\.colorScheme, .dark)
                if model.edit.captionStyleOrDefault.highlight != .none {
                    Toggle(isOn: boolBinding(\.evenSplit)) {
                        // 别用 textformat 一类的符号：中文环境下 SwiftUI 会挑本地化变体，画出来是「甲乙丙」三个汉字。
                        SettingLabel("按字均分", systemImage: "metronome",
                                     tip: "按字数均分句内时间，点亮更均匀")
                    }.toggleStyle(StudioToggleStyle())
                }
                Toggle(isOn: boolBinding(\.burnIn)) {
                    SettingLabel("烧录到画面", systemImage: "square.and.arrow.down",
                                 tip: "关闭后成片不含字幕，可另导出 SRT")
                }.toggleStyle(StudioToggleStyle())
                if !model.edit.captionStyleOrDefault.burnIn {
                    PanelNote("字幕不会烧进导出的视频，记得把 SRT 一起交付。")
                }
            }
            PanelSection("时间", expanded: $timingExpanded) {
                EditorStepper(model: model, title: "提前显示", value: numberBinding(\.lead), range: 0...1, defaultValue: 0.06)
                EditorStepper(model: model, title: "延后消失", value: numberBinding(\.tail), range: 0...2, defaultValue: 0.35)
                EditorStepper(model: model, title: "最短时长", value: numberBinding(\.minHold), range: 0.3...4, defaultValue: 1.0)
                EditorStepper(model: model, title: "衔接间隔", value: numberBinding(\.bridge), range: 0...1, defaultValue: 0.25)
                EditorStepper(model: model, title: "淡入", value: numberBinding(\.fadeIn), range: 0...1, defaultValue: 0.12)
                EditorStepper(model: model, title: "淡出", value: numberBinding(\.fadeOut), range: 0...1, defaultValue: 0.12)
            }
            PanelSection("这一句") {
                if let id = model.selectedCaption, let cue = model.edit.caption(id: id) {
                    TextEditor(text: textBinding(id))
                        .font(CaploFont.body).scrollContentBackground(.hidden)
                        .frame(minHeight: 54)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(CaploColor.surfaceRaised, in: RoundedRectangle(cornerRadius: CaploMetrics.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control, style: .continuous).strokeBorder(CaploColor.separator, lineWidth: 1))
                    Text("原素材 \(timecode(cue.sourceStart)) – \(timecode(cue.sourceEnd))")
                        .font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
                    if cue.locked {
                        PanelNote("这一句你改过，重新转写不会覆盖它。")
                    }
                    HStack(spacing: CaploMetrics.Spacing.s) {
                        Button("在播放头分割") { splitSelected(id) }.buttonStyle(StudioButtonStyle(.secondary, size: .small))
                        Button("并入下一句") { mergeSelected(id) }.buttonStyle(StudioButtonStyle(.secondary, size: .small))
                    }
                    Button("删除这一句") { model.deleteSelection() }.buttonStyle(StudioButtonStyle(.destructive, size: .small))
                } else {
                    PanelNote("在时间线的字幕轨上点一句来编辑它。")
                }
            }
        }
    }

    // MARK: 动作

    private func splitSelected(_ id: UUID) {
        guard let source = model.edit.sourceTime(at: model.skimPosition ?? model.position) else { return }
        model.commit { $0.splitCaption(id: id, atSource: source) }
    }
    private func mergeSelected(_ id: UUID) {
        let sorted = model.edit.captionList.sorted { $0.sourceStart < $1.sourceStart }
        guard let index = sorted.firstIndex(where: { $0.id == id }), index + 1 < sorted.count else { return }
        model.commit { $0.mergeCaption(id: id, with: sorted[index + 1].id) }
    }
    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "vtt") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "选择 SRT 或 VTT 字幕文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importCaptions(from: url)
    }
    private func exportFile(vtt: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: vtt ? "vtt" : "srt") ?? .plainText]
        panel.nameFieldStringValue = model.entry.document.name + (vtt ? ".vtt" : ".srt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.captionFileText(vtt: vtt).write(to: url, atomically: true, encoding: .utf8) }
        catch { model.error = "写不进这个文件：\(error.localizedDescription)" }
    }

    // MARK: 绑定

    private var sourceBinding: Binding<TranscriptionSource> {
        Binding(get: { model.captionSource }, set: { model.captionSource = $0 })
    }
    /// 语言下拉。`captionLocale` 默认跟随系统，标识符可能是 zh-Hans-CN 这类带地区脚本的形式，
    /// 对不上任何一个固定选项，所以认不出来时一律显示「跟随系统」，而不是留一格空白。
    private var localeBinding: Binding<String> {
        Binding(get: {
            let identifier = model.captionLocale.identifier.replacingOccurrences(of: "_", with: "-")
            return ["zh-CN", "en-US", "ja-JP"].contains(identifier) ? identifier : "system"
        }, set: { value in
            model.captionLocale = value == "system"
                ? Locale(identifier: Locale.preferredLanguages.first ?? "zh-CN")
                : Locale(identifier: value)
        })
    }
    private var highlightBinding: Binding<CaptionStyle.Highlight> {
        Binding(get: { model.edit.captionStyleOrDefault.highlight },
                set: { value in model.commit { $0.captionStyle = mutated($0) { $0.highlight = value } } })
    }
    private func styleBinding(_ key: WritableKeyPath<CaptionStyle, TextSegment.Family>) -> Binding<TextSegment.Family> {
        Binding(get: { model.edit.captionStyleOrDefault[keyPath: key] },
                set: { value in model.commit { $0.captionStyle = mutated($0) { $0[keyPath: key] = value } } })
    }
    private func boolBinding(_ key: WritableKeyPath<CaptionStyle, Bool>) -> Binding<Bool> {
        Binding(get: { model.edit.captionStyleOrDefault[keyPath: key] },
                set: { value in model.commit { $0.captionStyle = mutated($0) { $0[keyPath: key] = value } } })
    }
    /// 滑块直写，撤销快照交给 EditorSlider 的 begin/endInteraction。
    private func numberBinding(_ key: WritableKeyPath<CaptionStyle, Double>) -> Binding<Double> {
        Binding(get: { model.edit.captionStyleOrDefault[keyPath: key] },
                set: { value in
                    var style = model.edit.captionStyleOrDefault
                    style[keyPath: key] = value
                    model.edit.captionStyle = style
                })
    }
    private func textBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { model.edit.caption(id: id)?.text ?? "" }, set: { value in
            model.typeText { edit in
                edit.updateCaption(id: id) {
                    $0.text = String(value.prefix(CaptionCue.textLimit))
                    // 用户动过这一句：锁住它，重新转写不会覆盖。
                    $0.locked = true
                }
            }
        })
    }
    private func mutated(_ edit: VideoEdit, _ change: (inout CaptionStyle) -> Void) -> CaptionStyle {
        var style = edit.captionStyleOrDefault
        change(&style)
        return style
    }
}

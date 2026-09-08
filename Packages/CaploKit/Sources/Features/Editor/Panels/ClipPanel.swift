import SwiftUI
import CaploDesignSystem
import EditingCore

/// 片段：选中片段的音量增益与光标显隐；可把音量应用到全部片段。变速不在本轮范围。
struct ClipPanel: View {
    let model: VideoEditorModel

    private var role: TimelineMedia { model.selectedMedia ?? .screen }
    private var selected: (index: Int, clip: VideoClip)? {
        let values = model.edit.mediaClips(role)
        guard let id = model.selectedMediaID ?? model.selectedClip, let index = values.firstIndex(where: { $0.id == id }) else { return nil }
        return (index, values[index])
    }

    var body: some View {
        if let selected {
            let start = selected.clip.timelineStart ?? 0
            PanelSection("片段 \(selected.index + 1)") {
                HStack(spacing: CaploMetrics.Spacing.m) {
                    Text(TimelineTime.code(start)).font(CaploFont.value).foregroundStyle(CaploColor.textSecondary)
                    Text("时长 \(timecode(selected.clip.duration))").font(CaploFont.value).foregroundStyle(CaploColor.textSecondary)
                    if model.selectedClipIDs.count > 1 {
                        Text("已选 \(model.selectedClipIDs.count) 段").font(CaploFont.caption).foregroundStyle(CaploColor.textTertiary)
                    }
                }
            }
            if role == .system || role == .microphone {
                let track: AudioTrack = role == .system ? .system : .microphone
                PanelSection("本块音量", info: "与全局音量相乘，只影响当前声音块。") {
                    EditorSlider(model: model, title: "音量", value: gain(selected.clip.id, track), range: 0...2, suffix: "%", percentage: true, defaultValue: 1, detents: [1])
                }
            }
            if role == .screen {
            PanelSection("光标") {
                Toggle(isOn: Binding(get: { !selected.clip.cursorHidden }, set: { visible in
                    model.commit { edit in
                        for index in edit.clips.indices where edit.clips[index].id == selected.clip.id || model.selectedClipIDs.contains(edit.clips[index].id) {
                            edit.clips[index].cursorHidden = !visible
                        }
                    }
                })) { SettingLabel("在本片段显示光标", systemImage: "cursorarrow") }.toggleStyle(StudioToggleStyle())
                    .disabled(model.edit.pointer == nil)
                if model.edit.pointer == nil { PanelNote("此录制没有光标效果可以隐藏。") }
            }
            }
            if role == .screen, selected.clip.hasCustomSettings {
                Button("恢复片段默认") {
                    model.commit { edit in
                        guard let index = edit.clips.firstIndex(where: { $0.id == selected.clip.id }) else { return }
                        edit.clips[index].systemGain = 1; edit.clips[index].microphoneGain = 1; edit.clips[index].cursorHidden = false
                    }
                }.buttonStyle(StudioButtonStyle(.quiet, size: .small))
            }
        } else {
            PanelNote("在时间线上选中一个片段，调整它的音量与光标。")
        }
    }

    private func gain(_ id: UUID, _ track: AudioTrack) -> Binding<Double> {
        Binding(get: { Double(model.edit.mediaClips(role).first(where: { $0.id == id })?.gain(for: track) ?? 1) }, set: { value in
            var values = model.edit.mediaClips(role)
            guard let index = values.firstIndex(where: { $0.id == id }) else { return }
            if track == .system { values[index].systemGain = Float(value) } else { values[index].microphoneGain = Float(value) }
            model.edit.setMediaClips(role, values)
        })
    }
}

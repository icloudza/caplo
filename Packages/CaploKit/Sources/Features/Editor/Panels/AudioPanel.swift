import SwiftUI
import CaploDesignSystem
import EditingCore

/// 声音混合：系统声音与麦克风的音量、静音、独奏；与轨头按钮同步。
/// 时间线上选中某一块声音时，最上面多一组"这一块"的音量（原"片段设置"里唯一真正用得上的一项，2026-10-06 并进来）。
struct AudioPanel: View {
    let model: VideoEditorModel

    /// 时间线上选中的声音块：它所在的轨、块号与块本身。
    private var selectedBlock: (track: AudioTrack, role: TimelineMedia, number: Int, clip: VideoClip)? {
        guard let role = model.selectedMedia, role == .system || role == .microphone, let id = model.selectedMediaID else { return nil }
        let values = model.edit.mediaClips(role)
        guard let index = values.firstIndex(where: { $0.id == id }) else { return nil }
        return (role == .system ? .system : .microphone, role, index + 1, values[index])
    }

    var body: some View {
        if let block = selectedBlock {
            PanelSection("选中的\(block.track == .system ? "系统声音" : "麦克风")块 \(block.number)", info: "与轨道音量相乘，仅作用于此块") {
                EditorFill(model: model, title: "这一块的音量", value: blockGain(block.clip.id, role: block.role, track: block.track),
                           range: 0...2, suffix: "%", percentage: true, defaultValue: 1, detents: [1])
            }
        }
        ForEach(AudioTrack.allCases) { track in
            PanelSection(track == .system ? "系统声音" : "麦克风") {
                if model.audioTracks.contains(track) {
                    EditorFill(model: model, title: "音量", value: Binding(get: { Double(model.edit.audio[track]) }, set: { model.edit.audio[track] = Float($0) }), range: 0...1, suffix: "%", percentage: true, defaultValue: 1)
                    HStack(spacing: CaploMetrics.Spacing.s) {
                        Button("静音") { model.toggleMute(track) }
                            .buttonStyle(StudioButtonStyle(model.edit.audio.muted.contains(track) ? .primary : .secondary, size: .small))
                            .accessibilityAddTraits(model.edit.audio.muted.contains(track) ? .isSelected : [])
                        Button("仅播放此轨") { model.toggleSolo(track) }
                            .buttonStyle(StudioButtonStyle(model.edit.audio.solo.contains(track) ? .primary : .secondary, size: .small))
                            .accessibilityAddTraits(model.edit.audio.solo.contains(track) ? .isSelected : [])
                    }
                    if track == .microphone {
                        // 离线语音处理：以系统声音轨为参考消除扬声器串进麦克风的声音，再压底噪；处理一次后预览与导出共用。
                        Toggle(isOn: Binding(get: { model.edit.audio.voiceProcessing }, set: { model.setVoiceProcessing($0) })) {
                            SettingLabel("回声消除与降噪", systemImage: "waveform.badge.magnifyingglass")
                        }
                        .toggleStyle(StudioToggleStyle())
                        .disabled({ if case .processing = model.voiceProcessingState { return true } else { return false } }())
                        switch model.voiceProcessingState {
                        case .processing(let value): PanelNote("正在处理麦克风 \(Int(value * 100))%，完成后自动切换。")
                        case .failed(let message): PanelNote("处理失败：\(message)")
                        case .idle: PanelNote("以系统声音轨为参考消掉扬声器串进麦克风的声音，并压制底噪；离线处理一次，之后预览与导出共用，关闭即回到原始声音。")
                        }
                    }
                } else {
                    PanelNote("此录制没有这条音轨。")
                }
            }
        }
        PanelNote("静音保留原音量。“仅播放此轨”开启后只播放勾选的轨道；静音优先。调整即时试听，并应用于导出。")
    }

    private func blockGain(_ id: UUID, role: TimelineMedia, track: AudioTrack) -> Binding<Double> {
        Binding(get: { Double(model.edit.mediaClips(role).first(where: { $0.id == id })?.gain(for: track) ?? 1) }, set: { value in
            var values = model.edit.mediaClips(role)
            guard let index = values.firstIndex(where: { $0.id == id }) else { return }
            if track == .system { values[index].systemGain = Float(value) } else { values[index].microphoneGain = Float(value) }
            model.edit.setMediaClips(role, values)
        })
    }
}

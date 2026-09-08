import SwiftUI
import CaploDesignSystem
import EditingCore

/// 声音混合：系统声音与麦克风的音量、静音、独奏；与轨头按钮同步。
struct AudioPanel: View {
    let model: VideoEditorModel

    var body: some View {
        ForEach(AudioTrack.allCases) { track in
            PanelSection(track == .system ? "系统声音" : "麦克风") {
                if model.audioTracks.contains(track) {
                    EditorSlider(model: model, title: "音量", value: Binding(get: { Double(model.edit.audio[track]) }, set: { model.edit.audio[track] = Float($0) }), range: 0...1, suffix: "%", percentage: true, defaultValue: 1)
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
}

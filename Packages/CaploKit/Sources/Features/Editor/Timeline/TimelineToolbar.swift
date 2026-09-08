import SwiftUI
import EditingCore
import CaploDesignSystem

/// 时间线工具栏：剪辑动作 ｜ 撤销重做 ｜ 播放与时间 ｜ 吸附与缩放。作为固定高度的宿主视图放在时间线窗格顶部。
struct TimelineToolbar: View {
    let model: VideoEditorModel
    let viewport: TimelineViewport
    let addFocus: () -> Void

    var body: some View {
        HStack(spacing: CaploMetrics.Spacing.s) {
            // 工具栏只放图标，名称与快捷键都在悬停提示里。
            Button { model.split() } label: { SplitGlyph() }
                .buttonStyle(StudioIconButtonStyle())
                .keyboardShortcut("b", modifiers: .command).hoverTip(model.canSplit ? "在播放头分割 ⌘B" : "播放头两侧都要留下至少 0.25 秒才能分割")
                .accessibilityLabel("分割")
                .disabled(!model.canSplit)
            Button { model.deleteSelection() } label: { Image(systemName: "trash") }
                .buttonStyle(StudioIconButtonStyle()).hoverTip("删除选中的块或聚焦 ⌫").accessibilityLabel("删除选中")
                .disabled(!model.ready || (model.selectedClip == nil && model.selectedFocus == nil && model.selectedMediaID == nil))
            Button(action: addFocus) { Image(systemName: "plus.viewfinder") }
                .buttonStyle(StudioIconButtonStyle()).hoverTip("在播放头添加聚焦").accessibilityLabel("添加聚焦")
                .disabled(!model.ready || model.edit.clips.isEmpty)
            toolbarDivider
            // 静音 / 仅播放此轨作用于时间线上选中的音频块所在的轨道；轨头只留图标。
            audioToggle(solo: false)
            audioToggle(solo: true)
            toolbarDivider
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(StudioIconButtonStyle()).disabled(!model.history.canUndo)
                .hoverTip("撤销 ⌘Z").accessibilityLabel("撤销").keyboardShortcut("z", modifiers: .command)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(StudioIconButtonStyle()).disabled(!model.history.canRedo)
                .hoverTip("重做 ⇧⌘Z").accessibilityLabel("重做").keyboardShortcut("z", modifiers: [.command, .shift])
            Spacer(minLength: CaploMetrics.Spacing.s)
            Button { model.togglePlayback() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill") }
                .buttonStyle(StudioIconButtonStyle()).keyboardShortcut(.space, modifiers: [])
                .hoverTip(model.playing ? "暂停" : "播放").accessibilityLabel(model.playing ? "暂停" : "播放")
                .disabled(model.loading || (model.edit.duration <= 0) || !model.ready)
            HStack(spacing: 4) {
                Text(TimelineTime.code(model.position)).foregroundStyle(CaploColor.textPrimary)
                Text("/").foregroundStyle(CaploColor.textTertiary)
                Text(TimelineTime.code(model.edit.duration)).foregroundStyle(CaploColor.textSecondary)
            }.font(CaploFont.value)
            Spacer(minLength: CaploMetrics.Spacing.s)
            Button { viewport.snapping.toggle() } label: { Image(systemName: "arrow.right.and.line.vertical.and.arrow.left") }
                .buttonStyle(StudioIconButtonStyle(active: viewport.snapping))
                .hoverTip("边界吸附 · 拖动时按 ⌥ 暂时关闭").accessibilityLabel("边界吸附").accessibilityValue(viewport.snapping ? "开" : "关")
            toolbarDivider
            // 缩放下限 = 适合窗口的那一档，不能缩到整条时间线只占一小截。
            let minimumZoom = viewport.minimumZoom(for: model.edit.duration)
            Button { viewport.zoom = max(minimumZoom, viewport.zoom - 0.5) } label: { Image(systemName: "minus") }
                .buttonStyle(StudioIconButtonStyle(size: .small)).hoverTip("缩小时间线").accessibilityLabel("缩小时间线")
            CaliperSlider("时间线缩放", value: Binding(get: { viewport.zoom }, set: { viewport.zoom = $0 }),
                          configuration: CaliperConfiguration(track: .fixed, size: .compact, range: min(minimumZoom, 4)...4, step: 0.5, tickStep: 1, major: 4, mid: 2,
                                                              detents: [0], magnet: .detents, inertia: false, fade: .off, defaultValue: 0, damping: 0.18))
                .frame(width: 96, height: 26)
            Button { viewport.zoom = min(4, viewport.zoom + 0.5) } label: { Image(systemName: "plus") }
                .buttonStyle(StudioIconButtonStyle(size: .small)).hoverTip("放大时间线").accessibilityLabel("放大时间线")
            Button { viewport.fit(duration: model.edit.duration) } label: { Image(systemName: "arrow.left.and.right.square") }
                .buttonStyle(StudioIconButtonStyle()).hoverTip("缩放到适合窗口").accessibilityLabel("适合窗口")
        }
        .padding(.horizontal, CaploMetrics.Spacing.m)
        .frame(height: CaploMetrics.toolbarHeight)
    }

    private var selectedAudioTrack: AudioTrack? {
        switch model.selectedMedia { case .system: .system; case .microphone: .microphone; default: nil }
    }

    private func audioToggle(solo: Bool) -> some View {
        let track = selectedAudioTrack
        let available = track.map { model.audioTracks.contains($0) } ?? false
        let active = track.map { (solo ? model.edit.audio.solo : model.edit.audio.muted).contains($0) } ?? false
        let name = track == .system ? "系统声音" : track == .microphone ? "麦克风" : nil
        return Button { if let track { solo ? model.toggleSolo(track) : model.toggleMute(track) } } label: {
            Text(solo ? "S" : "M").font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .buttonStyle(StudioIconButtonStyle(size: .small, active: active))
        .disabled(!available || !model.ready)
        .hoverTip(name.map { (solo ? "仅播放此轨 · " : "静音 · ") + $0 } ?? "先在时间线上选中一条音频块")
        .accessibilityLabel((name ?? "音频") + (solo ? "仅播放此轨" : "静音"))
        .accessibilityValue(active ? "开" : "关")
    }

    private var toolbarDivider: some View {
        Rectangle().fill(CaploColor.separator).frame(width: CaploMetrics.hairline, height: 20).accessibilityHidden(true)
    }
}

/// 分割图标 "]|["：两个圆角半框相对，中间一道切线。
private struct SplitGlyph: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height, r: CGFloat = 2.5, inset: CGFloat = 0.8
            let arm: CGFloat = 5, top = inset, bottom = h - inset
            // 左半框：开口朝左，右侧两个角是圆的。
            var left = Path()
            left.move(to: CGPoint(x: 0, y: top))
            left.addLine(to: CGPoint(x: arm - r, y: top)); left.addQuadCurve(to: CGPoint(x: arm, y: top + r), control: CGPoint(x: arm, y: top))
            left.addLine(to: CGPoint(x: arm, y: bottom - r)); left.addQuadCurve(to: CGPoint(x: arm - r, y: bottom), control: CGPoint(x: arm, y: bottom))
            left.addLine(to: CGPoint(x: 0, y: bottom))
            var right = Path()
            right.move(to: CGPoint(x: w, y: top))
            right.addLine(to: CGPoint(x: w - arm + r, y: top)); right.addQuadCurve(to: CGPoint(x: w - arm, y: top + r), control: CGPoint(x: w - arm, y: top))
            right.addLine(to: CGPoint(x: w - arm, y: bottom - r)); right.addQuadCurve(to: CGPoint(x: w - arm + r, y: bottom), control: CGPoint(x: w - arm, y: bottom))
            right.addLine(to: CGPoint(x: w, y: bottom))
            var cut = Path()
            cut.move(to: CGPoint(x: w / 2, y: top - 0.3)); cut.addLine(to: CGPoint(x: w / 2, y: bottom + 0.3))
            let style = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            context.stroke(left, with: .foreground, style: style)
            context.stroke(right, with: .foreground, style: style)
            context.stroke(cut, with: .foreground, style: style)
        }
        .frame(width: 17, height: 12)
        .accessibilityHidden(true)
    }
}

import SwiftUI
import EditingCore
import CaploDesignSystem

/// 时间线工具栏：剪辑动作（分割、删除、聚焦、卡片） ｜ 撤销重做 ｜ 播放与时间 ｜ 吸附与缩放。作为固定高度的宿主视图放在时间线窗格顶部。
struct TimelineToolbar: View {
    let model: VideoEditorModel
    let viewport: TimelineViewport
    let addFocus: () -> Void
    private let shortcuts = ShortcutStore.shared

    var body: some View {
        HStack(spacing: CaploMetrics.Spacing.s) {
            // 工具栏只放图标，名称与快捷键都在悬停提示里。
            Button { model.split() } label: { SplitGlyph() }
                .buttonStyle(StudioIconButtonStyle())
                .shortcut(.split).hoverTip(model.canSplit ? String(localized: "分割 \(shortcuts.display(.split))") : String(localized: "两侧需各留 0.25 秒"))
                .accessibilityLabel("分割")
                .disabled(!model.canSplit)
            Button { model.deleteSelection() } label: { Image(systemName: "trash") }
                .buttonStyle(StudioIconButtonStyle()).hoverTip(String(localized: "删除 ⌫")).accessibilityLabel("删除选中")
                .disabled(!model.ready || (model.selectedClip == nil && model.selectedFocus == nil && model.selectedMediaID == nil))
            Button(action: addFocus) { Image(systemName: "plus.viewfinder") }
                .buttonStyle(StudioIconButtonStyle()).hoverTip(String(localized: "添加聚焦")).accessibilityLabel("添加聚焦")
                .disabled(!model.ready || model.edit.clips.isEmpty)
            // 卡片：片头 / 章节 / 片尾。插在播放头处，落在画面中间会在那里切开，后面的内容往后挪。
            Button { model.insertCard() } label: { Image(systemName: "rectangle.badge.plus") }
                .buttonStyle(StudioIconButtonStyle()).hoverTip(String(localized: "插入卡片"))
                .accessibilityLabel("插入卡片")
                .disabled(!model.ready)
            toolbarDivider
            // 静音 / 仅播放此轨作用于时间线上选中的音频块所在的轨道；轨头只留图标。
            audioToggle(solo: false)
            audioToggle(solo: true)
            toolbarDivider
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(StudioIconButtonStyle()).disabled(!model.history.canUndo)
                .hoverTip(String(localized: "撤销 \(shortcuts.display(.undo))")).accessibilityLabel("撤销").shortcut(.undo)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(StudioIconButtonStyle()).disabled(!model.history.canRedo)
                .hoverTip(String(localized: "重做 \(shortcuts.display(.redo))")).accessibilityLabel("重做").shortcut(.redo)
            Spacer(minLength: CaploMetrics.Spacing.s)
            Button { model.togglePlayback() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill") }
                .buttonStyle(StudioIconButtonStyle()).shortcut(.playPause)
                .hoverTip(model.playing ? String(localized: "暂停 \(shortcuts.display(.playPause))") : String(localized: "播放 \(shortcuts.display(.playPause))")).accessibilityLabel(model.playing ? "暂停" : "播放")
                .disabled(model.loading || (model.edit.duration <= 0) || !model.ready)
            HStack(spacing: 4) {
                Text(TimelineTime.code(model.position)).foregroundStyle(CaploColor.textPrimary)
                Text("/").foregroundStyle(CaploColor.textTertiary)
                Text(TimelineTime.code(model.edit.duration)).foregroundStyle(CaploColor.textSecondary)
            }.font(CaploFont.value)
            Spacer(minLength: CaploMetrics.Spacing.s)
            Button { viewport.snapping.toggle() } label: { Image(systemName: "arrow.right.and.line.vertical.and.arrow.left") }
                .buttonStyle(StudioIconButtonStyle(active: viewport.snapping))
                .hoverTip(String(localized: "吸附 · ⌥ 临时关闭")).accessibilityLabel("边界吸附").accessibilityValue(viewport.snapping ? "开" : "关")
            toolbarDivider
            // 缩放：图标 + 细滑条（参照 Logic），连续拖动；倍率是 2 的指数，线性拖动即等比缩放。
            // 下限 = 适合窗口的那一档，不能缩到整条时间线只占一小截；双击滑条回到适合窗口。
            let minimumZoom = min(viewport.minimumZoom(for: model.edit.duration), 4)
            ThinSlider(String(localized: "时间线缩放"), systemImage: "arrow.left.and.right", value: Binding(get: { viewport.zoom }, set: { viewport.zoom = $0 }),
                       in: minimumZoom...max(4, minimumZoom + 0.5), onReset: { viewport.fit(duration: model.edit.duration) })
                .frame(width: 104)
                .hoverTip(String(localized: "缩放"))
            Button { viewport.fit(duration: model.edit.duration) } label: { Image(systemName: "arrow.left.and.right.square") }
                .buttonStyle(StudioIconButtonStyle()).hoverTip(String(localized: "适合窗口")).accessibilityLabel("适合窗口")
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
        let name = track == .system ? String(localized: "系统声音") : track == .microphone ? String(localized: "麦克风") : nil
        return Button { if let track { solo ? model.toggleSolo(track) : model.toggleMute(track) } } label: {
            Text(solo ? "S" : "M").font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .buttonStyle(StudioIconButtonStyle(size: .small, active: active))
        .disabled(!available || !model.ready)
        .hoverTip(name.map { (solo ? String(localized: "仅播放此轨 · ") : String(localized: "静音 · ")) + $0 } ?? String(localized: "先选中音频块"))
        .accessibilityLabel((name ?? String(localized: "音频")) + (solo ? String(localized: "仅播放此轨") : String(localized: "静音")))
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

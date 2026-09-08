import SwiftUI
import AVFoundation
import Observation
import ProjectKit
import ExportKit
import EditingCore

/// 编辑会话独占元数据租约，提交即原子保存；片段变化才重建播放器。
/// 画布像素只有一条通道：播放器按当前合成渲染的帧经 `CanvasPresenter` 直接上屏——播放、拖动定位、
/// 样式拖动（每一步都换一份合成，播放器用已解码的当前帧重渲染）共用同一路径；没有播放项时才用离线静帧兜底。
@MainActor @Observable
final class VideoEditorModel {
    let entry: LibraryEntry
    let player = AVPlayer()
    @ObservationIgnored let canvas = CanvasPresenter()
    let audioTracks: Set<AudioTrack>
    var edit: VideoEdit
    var history = EditHistory()
    var selectedClip: UUID?
    var selectedClipIDs: Set<UUID> = []
    var selectedMedia: TimelineMedia?
    var selectedMediaID: UUID?
    var selectedFocus: UUID?
    var position = 0.0
    /// 鼠标掠览只改变画布定位，不改播放头、选区或工程；移出后恢复播放头画面。
    private(set) var skimPosition: Double?
    var playing = false
    /// 还没有可用的播放项（初次打开或时间线为空）；只有这时画布才显示"载入画面"。
    var loading = true
    /// 片段变化后正在静默重建播放项；期间画布保留上一帧，定位用离线静帧兜底。
    private(set) var rebuilding = false
    var ready = false
    var error: String?
    var saveStatus = "正在打开…"
    var analysis = TimelineAnalysis()
    var progress = 0.0
    var exporting = false
    var exportSize = 1920
    var exportedURL: URL?
    private var lease: ProjectLease?
    private var reloadTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var posterTask: Task<Void, Never>?
    private let previewRenderer = EditorPreviewRenderer()
    /// 离线静帧请求：`force` 属于请求本身——裁剪边缘超出播放项范围时即使播放项就绪也要上屏。
    private var pendingFallback: (revision: UInt64, edit: VideoEdit, time: Double, force: Bool)?
    /// 画面代次：播放器定位与离线渲染共用，任何一次播放器定位都让更早的离线请求作废。
    private var fallbackRevision: UInt64 = 0
    /// 当前播放项对应的编辑；`rebuildingEdit` 是在途重建所用的快照。
    private var presentedEdit: VideoEdit?
    private var rebuildingEdit: VideoEdit?
    private var seekTask: Task<Void, Never>?
    private var seekRevision: UInt64 = 0
    private var pendingSeek: Double?
    private var playAfterSeek = false
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var interactionStart: VideoEdit?
    private var interactionChangesVisual = false
    /// 裁剪拖动期间画布显示的是边缘帧而不是播放头帧；交互结束（取消、无变化、松手）后要把画布拉回播放头。
    private var edgePreview: (source: Double, clip: UUID?)?
    /// 指针事件只解析一次；重建播放项不再在主线程重复解 JSON。
    private var pointers: PointerTimeline?
    /// 光标大小滑块的下限：与录制时系统光标同大的倍率；素材未载入或旧工程没有真实光标时按 0.5。
    var systemCursorScale: Double { pointers?.systemCursorScale ?? 0.5 }
    private var closed = false
    /// 麦克风离线语音处理（回声消除与降噪）的进度：打开开关时先在后台把每个片段处理成产物，完成后才切换编辑数据。
    enum VoiceProcessingState: Equatable { case idle, processing(Double), failed(String) }
    private(set) var voiceProcessingState = VoiceProcessingState.idle
    private var voiceProcessingTask: Task<Void, Never>?

    init(entry: LibraryEntry) {
        self.entry = entry; edit = VideoEdit(duration: entry.document.duration)
        audioTracks = Set(AudioTrack.allCases.filter { track in
            entry.document.segments.contains { $0.files[track == .system ? .systemAudio : .microphone] != nil }
        })
    }

    /// 本工程当前有没有可编辑的人像：录制时开了摄像头，且摄像头片段没有被从时间线上删光。
    /// 人像面板与工具栏"人像"项都以此为准；`cameraClips == nil` 表示跟随录屏片段，视为有。
    var hasCameraMedia: Bool {
        entry.document.segments.contains { $0.files[.camera] != nil } && !edit.mediaClips(.camera).isEmpty
    }
    /// 录制时开了摄像头，但片段已被删光（区别于根本没录摄像头）。
    var cameraClipsDeleted: Bool {
        entry.document.segments.contains { $0.files[.camera] != nil } && edit.mediaClips(.camera).isEmpty
    }

    func toggleMute(_ track: AudioTrack) {
        guard audioTracks.contains(track) else { return }
        commit { if !$0.audio.muted.insert(track).inserted { $0.audio.muted.remove(track) } }
    }
    /// 打开：已有产物直接切换；否则后台逐片段处理（跳过已有的），完成后切换（重建播放项）。关闭：直接回到原始麦克风。
    func setVoiceProcessing(_ enabled: Bool) {
        guard audioTracks.contains(.microphone) else { return }
        voiceProcessingTask?.cancel(); voiceProcessingTask = nil
        guard enabled else { voiceProcessingState = .idle; commit { $0.audio.voiceProcessing = false }; return }
        if VoiceProcessor.isProcessed(project: entry.url, document: entry.document) { voiceProcessingState = .idle; commit { $0.audio.voiceProcessing = true }; return }
        voiceProcessingState = .processing(0)
        let url = entry.url, document = entry.document
        voiceProcessingTask = Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await VoiceProcessor.process(project: url, document: document) { value in
                        Task { @MainActor in self?.voiceProcessingState = .processing(value) }
                    }
                }.value
                guard let self, !Task.isCancelled, !self.closed else { return }
                self.voiceProcessingState = .idle
                self.commit { $0.audio.voiceProcessing = true }
            } catch is CancellationError {
            } catch { self?.voiceProcessingState = .failed(error.localizedDescription) }
        }
    }

    func toggleSolo(_ track: AudioTrack) {
        guard audioTracks.contains(track) else { return }
        commit { if !$0.audio.solo.insert(track).inserted { $0.audio.solo.remove(track) } }
    }

    func open() async {
        guard lease == nil, !closed, !Task.isCancelled else { return }
        do {
            lease = try ProjectLease(url: entry.url)
            edit = try EditStorage.load(in: entry.url, document: entry.document)
            edit.prepareLayerEditing(camera: entry.document.segments.contains { $0.files[.camera] != nil }, system: audioTracks.contains(.system), microphone: audioTracks.contains(.microphone))
            selectedClip = edit.clips.first?.id
            selectedClipIDs = Set(edit.clips.prefix(1).map(\.id))
            ready = true; saveStatus = "已保存"
            VideoEditorSessions.current = self
            // 初次自动生成镜头也落盘，重新打开时保持相同结果。
            try EditStorage.save(edit, in: entry.url, document: entry.document)
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    // 暂停定位时播放器回调可能仍是旧时间，不能覆盖用户正在拖动的播放头；重建中旧播放项的时间线已失效。
                    guard self.playing, self.seekTask == nil, !self.loading, !self.rebuilding else { return }
                    if time.seconds.isFinite { self.position = min(self.edit.duration, max(0, time.seconds)) }
                    self.playing = self.player.rate != 0
                }
            }
            // 播放到结尾自动回到暂停态，播放头停在末尾；再按播放从头开始（togglePlayback 已处理）。
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
                // 通知对象不是 Sendable，只把它的身份带进主线程闭包比较。
                let ended = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, !self.closed, let ended, let current = self.player.currentItem, ObjectIdentifier(current) == ended else { return }
                    self.pause()
                    self.position = self.edit.duration
                }
            }
            reload()
            analysisTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await TimelineAnalysis.load(url: entry.url, document: entry.document)
                    try Task.checkCancellation(); analysis = result
                } catch is CancellationError {} catch { self.error = "时间线预览生成失败：\(error.localizedDescription)" }
            }
        } catch { self.error = error.localizedDescription; saveStatus = "未能打开编辑"; ready = false; loading = false; lease = nil }
    }

    func commit(_ change: (inout VideoEdit) -> Void) {
        guard ready else { return }
        let previous = edit
        change(&edit)
        if edit.focuses.contains(where: { $0.timelineStart == nil }) {
            edit.prepareLayerEditing(camera: entry.document.segments.contains { $0.files[.camera] != nil }, system: audioTracks.contains(.system), microphone: audioTracks.contains(.microphone))
        }
        finishChange(previous: previous)
    }
    func beginInteraction() {
        skim(nil)
        if interactionStart == nil { interactionStart = edit; interactionChangesVisual = false }
    }
    func cancelInteraction() {
        guard let previous = interactionStart else { return }
        interactionStart = nil; edit = previous; normalizeSelection(); refreshPresentation()
        restorePlayheadFrame()
    }
    func endInteraction() {
        guard let previous = interactionStart else { return }; interactionStart = nil
        finishChange(previous: previous)
    }
    private func finishChange(previous: VideoEdit) {
        guard edit != previous else { restorePlayheadFrame(); return }
        edit.constrainTimelineFocuses()
        edit.normalizeTimelineRows()
        do { try edit.validate(sourceDuration: entry.document.duration) }
        catch { edit = previous; self.error = error.localizedDescription; restorePlayheadFrame(); return }
        history.record(previous)
        edgePreview = nil
        save(); normalizeSelection(); refreshPresentation()
    }
    /// 裁剪交互没有产生新的时间线（取消、拖回原位、校验失败）：画布从边缘帧回到播放头那一帧。
    private func restorePlayheadFrame() {
        guard edgePreview != nil else { return }
        edgePreview = nil
        if loading || rebuilding || player.currentItem == nil { refreshFallbackFrame() } else { requestPlayerSeek() }
    }
    func retrySave() { save(); if saveStatus == "已保存" { error = nil } }
    private func save() {
        guard lease != nil, ready else { return }
        do { try EditStorage.save(edit, in: entry.url, document: entry.document); saveStatus = "已保存" }
        catch { saveStatus = "保存失败"; self.error = error.localizedDescription }
    }
    func undo() {
        guard let previous = history.undo(current: edit) else { return }
        edit = previous; save(); normalizeSelection(); refreshPresentation()
    }
    func redo() {
        guard let next = history.redo(current: edit) else { return }
        edit = next; save(); normalizeSelection(); refreshPresentation()
    }
    private func normalizeSelection() {
        if let role = selectedMedia, let id = selectedMediaID, !edit.mediaClips(role).contains(where: { $0.id == id }) {
            selectedMedia = nil; selectedMediaID = nil
        }
        selectedClipIDs.formIntersection(Set(edit.clips.map(\.id)))
        if !edit.clips.contains(where: { $0.id == selectedClip }) { selectedClip = edit.clips.first?.id }
        if !edit.focuses.contains(where: { $0.id == selectedFocus }) { selectedFocus = nil }
        position = min(position, edit.duration)
        if let skimPosition { self.skimPosition = min(skimPosition, edit.duration) }
    }
    /// 距片段边缘不足最小时长时不能分割：工具栏按钮已禁用，快捷键则给出提示音而不是静默无效。
    var canSplit: Bool { canSplit(at: position) }
    /// 某个时间线时刻能否分割当前选中的块（两侧都要留下最小时长）；右键菜单用它判断"在此处分割"。
    func canSplit(at time: Double) -> Bool {
        guard ready, selectedFocus == nil, time.isFinite else { return false }
        if let role = selectedMedia, let id = selectedMediaID, let clip = edit.mediaClips(role).first(where: { $0.id == id }) {
            let offset = time - (clip.timelineStart ?? 0)
            return offset >= VideoEdit.minimumClipDuration && clip.duration - offset >= VideoEdit.minimumClipDuration
        }
        if let id = selectedClip, let clip = edit.clips.first(where: { $0.id == id }) {
            let offset = time - (clip.timelineStart ?? 0)
            return offset >= VideoEdit.minimumClipDuration && clip.duration - offset >= VideoEdit.minimumClipDuration
        }
        return false
    }
    func split() { split(at: position) }
    func split(at time: Double) {
        guard canSplit(at: time) else { NSSound.beep(); return }
        let role = selectedMedia ?? .screen
        guard let id = selectedMediaID ?? selectedClip else { return }
        var tailID: UUID?
        commit { tailID = $0.splitMedia(role, id: id, at: time) }
        // 媒体数组不是时间线行顺序：核心返回实际尾段，连续分割不能按相邻数组下标猜测。
        guard let tailID, edit.mediaClips(role).contains(where: { $0.id == tailID }) else { return }
        if role == .screen { selectClip(tailID) }
        else { selectedMedia = role; selectedMediaID = tailID; selectedFocus = nil }
    }
    /// 重命名时间线上的块；空白恢复默认名称。同一次编辑历史。
    func renameBlock(_ id: UUID, to title: String) {
        commit { $0.renameBlock(id, title: title) }
    }
    func deleteSelection() {
        if let role = selectedMedia, let id = selectedMediaID {
            commit { edit in edit.setMediaClips(role, edit.mediaClips(role).filter { $0.id != id }) }
            selectedMedia = nil; selectedMediaID = nil; return
        }
        if let selectedFocus { commit { $0.focuses.removeAll { $0.id == selectedFocus } } }
        else {
            let ids = selectedClipIDs.isEmpty ? Set([selectedClip].compactMap { $0 }) : selectedClipIDs
            commit { $0.clips.removeAll { ids.contains($0.id) } }
        }
    }
    func selectClip(_ id: UUID, extending: Bool = false, range: Bool = false) {
        selectedMedia = nil; selectedMediaID = nil
        if range, let selectedClip, let start = edit.clips.firstIndex(where: { $0.id == selectedClip }), let end = edit.clips.firstIndex(where: { $0.id == id }) {
            selectedClipIDs.formUnion(edit.clips[min(start, end)...max(start, end)].map(\.id))
        } else if extending {
            if selectedClipIDs.contains(id) { selectedClipIDs.remove(id) } else { selectedClipIDs.insert(id) }
            selectedClip = selectedClipIDs.contains(id) ? id : edit.clips.first(where: { selectedClipIDs.contains($0.id) })?.id
        } else { selectedClip = id; selectedClipIDs = [id] }
        selectedFocus = nil
    }
    func duplicateSelection() {
        if let id = selectedFocus, var copy = edit.focuses.first(where: { $0.id == id }) {
            copy.id = UUID(); copy.timelineStart = copy.editingStart + copy.duration
            commit { edit in edit.focuses.append(copy); edit.moveLayer(copy.id, before: id) }; selectedFocus = copy.id; return
        }
        if let role = selectedMedia, let id = selectedMediaID, var copy = edit.mediaClips(role).first(where: { $0.id == id }) {
            copy.id = UUID(); copy.timelineStart = (copy.timelineStart ?? 0) + copy.duration
            commit { edit in var values = edit.mediaClips(role); values.append(copy); edit.setMediaClips(role, values); edit.moveLayer(copy.id, before: id) }
            selectedMediaID = copy.id; return
        }
        let ids = selectedClipIDs.isEmpty ? Set([selectedClip].compactMap { $0 }) : selectedClipIDs
        var copies: Set<UUID> = []
        commit { edit in copies = edit.duplicateClips(ids); for id in copies { edit.moveLayer(id, before: selectedClip) } }
        selectedClipIDs = copies; selectedClip = edit.clips.first(where: { copies.contains($0.id) })?.id
    }
    func addFocus() {
        guard let clip = edit.clips.first(where: { $0.id == selectedClip }) ?? edit.clip(atTimeline: position) else { return }
        let start = clip.timelineStart ?? 0
        let anchor = position >= start && position < start + clip.duration ? position : start
        var zoom = FocusSegment(start: clip.sourceStart + min(anchor - start, clip.playableDuration - 0.00001), duration: min(2, start + clip.duration - anchor), x: 0.5, y: 0.5)
        guard zoom.duration > 0 else { return }
        zoom.timelineStart = anchor; zoom.targetClipID = clip.id; zoom.followsTimeline = true
        commit { edit in edit.focuses.append(zoom); edit.moveLayer(zoom.id, before: clip.id) }
        selectedMedia = nil; selectedMediaID = nil; selectedFocus = zoom.id
    }
    /// 请时间线把某个块滚进视口（面板里点了镜头列表 / 轨头图标时）；序号递增让同一块可以重复触发。
    private(set) var revealRequest: (id: UUID, serial: Int)?
    func reveal(_ id: UUID) { revealRequest = (id, (revealRequest?.serial ?? 0) &+ 1) }

    /// 播放器不能正好定位到时间线末尾：合成在那一刻没有画面样本，只会画出背景。末尾一律停在最后一帧的中间。
    nonisolated static func seekTarget(_ target: Double, duration: Double, frameRate: Double) -> Double {
        guard duration > 0 else { return max(0, target) }
        return min(target, max(0, duration - 0.5 / max(24, frameRate)))
    }

    /// 自定义布局对话框：当前播放头处的录屏与摄像头原帧。
    func layoutStills() async -> (screen: CGImage?, camera: CGImage?) {
        (try? await previewRenderer.stills(url: entry.url, document: entry.document, edit: edit, time: skimPosition ?? position)) ?? (nil, nil)
    }

    func seek(_ value: Double) {
        guard value.isFinite, !closed else { return }
        player.pause(); playing = false; playAfterSeek = false
        skimPosition = nil
        position = min(edit.duration, max(0, value))
        // 播放项正在按新时间线重建时，旧播放项的时间映射已经不对，用离线静帧兜底；否则定位完成的帧由播放器输出送到画布。
        if loading || rebuilding || player.currentItem == nil { refreshFallbackFrame() } else { requestPlayerSeek() }
    }
    /// 暂停时沿鼠标实时查看画面。复用串行定位队列，快速移动只追赶最新请求，不生成额外缓存。
    func skim(_ value: Double?) {
        guard !closed, ready else { return }
        if let value {
            guard value.isFinite, !playing, !playAfterSeek, interactionStart == nil else { return }
            let target = min(edit.duration, max(0, value))
            guard skimPosition != target else { return }
            skimPosition = target
        } else {
            guard skimPosition != nil else { return }
            skimPosition = nil
        }
        if loading || rebuilding || player.currentItem == nil { refreshFallbackFrame() } else { requestPlayerSeek() }
    }
    /// 定位请求只允许一个执行；等待完成后直接追赶最新位置，避免每次鼠标移动取消上一次 seek。
    private func requestPlayerSeek(to target: Double? = nil) {
        guard !loading, player.currentItem != nil, !closed else { return }
        // 播放器定位产生的是最新画面，更早排队的离线静帧不得再盖上来。
        fallbackRevision &+= 1; pendingFallback = nil
        pendingSeek = Self.seekTarget(target ?? skimPosition ?? position, duration: edit.duration, frameRate: entry.document.frameRate)
        guard seekTask == nil else { return }
        let revision = seekRevision
        seekTask = Task { [weak self] in
            guard let self else { return }
            defer { if revision == seekRevision { seekTask = nil } }
            while let target = pendingSeek, !Task.isCancelled, !closed {
                pendingSeek = nil
                await player.seek(to: CMTime(seconds: target, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if playAfterSeek, revision == seekRevision, !closed, !Task.isCancelled {
                playAfterSeek = false; player.play(); playing = true
            }
        }
    }
    func togglePlayback() {
        if playing || playAfterSeek { pause(); return }
        let wasSkimming = skimPosition != nil
        skimPosition = nil
        if position >= edit.duration - 0.04 { seek(0) }
        else if wasSkimming {
            // 播放器可能还停在鼠标位置，必须排队定位回主播放头后起播。
            if loading || rebuilding || player.currentItem == nil { refreshFallbackFrame() }
            else { requestPlayerSeek(to: position) }
        }
        // 定位未完成或播放项正在重建：先记住"定位完成后起播"，不能让旧播放项从错误的时间播出来。
        if seekTask != nil || rebuilding || loading { playAfterSeek = true }
        else { player.play(); playing = true }
    }
    func pause() {
        player.pause(); playing = false; playAfterSeek = false
    }
    /// 画布、镜头、音量的变化直接换到同一个播放项上：播放器用已解码的当前帧按新合成重渲染并送到画布，
    /// 播放中也不打断；只有片段变化才重建播放项。
    private func refreshPresentation() {
        if rebuilding {
            if let presented = presentedEdit, let item = player.currentItem, presented.hasSameMedia(as: edit) {
                // 撤销 / 重做回到了现有播放项的片段：在途重建作废，继续用手上这个播放项。
                cancelReload()
                if presented != edit { applyPresentation(item: item, previous: presented) }
                requestPlayerSeek()
                return
            }
            // 片段与在途快照一致（比如重建期间拖样式滑块）：不打断构建，完成时按最新编辑换一次合成。
            if let building = rebuildingEdit, building.hasSameMedia(as: edit) { return }
            reload(); return
        }
        guard !loading, let item = player.currentItem, let previous = presentedEdit, previous.hasSameMedia(as: edit) else {
            reload(); return
        }
        guard previous != edit else { return }
        applyPresentation(item: item, previous: previous)
        nudgePausedFrame()
    }
    /// 暂停时换了合成：系统不保证用新合成重画当前帧（播放过再暂停之后尤其常见，画面停在旧样式上），
    /// 原地定位一次强制按新合成重画；定位目标取播放器的实际时间，不会换到相邻帧。播放中帧在持续到达，不需要。
    private func nudgePausedFrame() {
        guard !playing, !playAfterSeek, !loading, !rebuilding, player.currentItem != nil else { return }
        let current = player.currentTime().seconds
        requestPlayerSeek(to: skimPosition ?? (current.isFinite ? current : position))
    }
    private func applyPresentation(item: AVPlayerItem, previous: VideoEdit) {
        do {
            try ProjectMedia.updatePresentation(item: item, previous: previous, edit: edit, url: entry.url)
            presentedEdit = edit
        } catch { self.error = error.localizedDescription }
    }
    private func cancelReload() {
        reloadTask?.cancel(); reloadTask = nil
        rebuildingEdit = nil; rebuilding = false
    }
    /// 片段变化后重建播放项。已有播放项时静默进行：画布保留上一帧（不发起离线静帧，也不显示"载入画面"），
    /// 新播放项就绪后在当前位置定位，帧到达即替换；只有初次打开或时间线为空时才进入 `loading`。
    func reload() {
        reloadTask?.cancel()
        seekRevision &+= 1
        seekTask?.cancel(); seekTask = nil; pendingSeek = nil; playAfterSeek = false
        player.currentItem?.cancelPendingSeeks()
        player.pause(); playing = false
        guard edit.duration > 0 else {
            player.replaceCurrentItem(with: nil); canvas.attach(item: nil); presentedEdit = nil; rebuildingEdit = nil
            loading = false; rebuilding = false; return
        }
        if player.currentItem == nil {
            loading = true
            // 还没有任何画面时先用离线静帧显示当前位置。
            refreshFallbackFrame()
        } else { rebuilding = true }
        let snapshot = edit
        rebuildingEdit = snapshot
        reloadTask = Task {
            do {
                let pointers = try await loadPointers()
                let item = try await ProjectMedia.playerItem(url: entry.url, document: entry.document, levels: snapshot.audio, edit: snapshot, pointers: pointers)
                try Task.checkCancellation()
                guard !closed else { return }
                player.replaceCurrentItem(with: item)
                canvas.attach(item: item)
                presentedEdit = snapshot; rebuildingEdit = nil
                loading = false; rebuilding = false
                if edit != snapshot {
                    // 构建期间编辑又变了：片段相同就换合成，否则再建一次（由新的 reload 负责定位）。
                    if edit.hasSameMedia(as: snapshot) { applyPresentation(item: item, previous: snapshot) } else { reload(); return }
                }
                // 构建期间仍可拖动：正在裁剪就定位到边缘帧，否则用完成时的最新播放头位置；定位完成的帧由播放器输出送到画布。
                if interactionStart != nil, let edge = edgePreview, let presented = presentedEdit, let time = presented.timelineTime(forSource: edge.source, in: edge.clip) {
                    requestPlayerSeek(to: min(presented.duration, max(0, time)))
                } else { requestPlayerSeek() }
            } catch is CancellationError {} catch {
                // 重建失败时不能把旧播放项当成"已就绪"：撤下旧项，定位走离线兜底，下一次片段变化会再次重建。
                self.error = error.localizedDescription
                rebuildingEdit = nil; rebuilding = false; loading = false
                player.replaceCurrentItem(with: nil); canvas.attach(item: nil); presentedEdit = nil
                refreshFallbackFrame()
            }
        }
    }
    /// 源事件在后台加载；完成后只替换自动镜头，保留手动编辑与统一撤销记录。
    func regenerateFocus() async {
        let url = entry.url, document = entry.document
        let style = edit.focusStyle ?? AutoFocusStyle()
        do {
            let generated = try await Task.detached(priority: .userInitiated) {
                AutoFocus.generate(events: try EditStorage.events(in: url, document: document), duration: document.duration, style: style)
            }.value
            guard !closed, (edit.focusStyle ?? AutoFocusStyle()) == style else { return }
            commit { edit in edit.focuses.removeAll { $0.automatic }; edit.focuses.append(contentsOf: generated); edit.automaticFocus = true; edit.focusEngineVersion = 2 }
        } catch { self.error = error.localizedDescription }
    }

    func setFocusFollowing(_ id: UUID, enabled: Bool) async {
        guard let segment = edit.focuses.first(where: { $0.id == id }) else { return }
        if !enabled || segment.timelineStart != nil {
            // 显式时间线跟随保存意图，路径随可见素材重新编译，拖长后无需再次切换开关。
            commit { edit in
                guard let index = edit.focuses.firstIndex(where: { $0.id == id }) else { return }
                edit.focuses[index].followsTimeline = enabled
                edit.focuses[index].path = nil; edit.focuses[index].sampledPath = nil
                edit.focuses[index].automatic = false
            }
            return
        }
        let url = entry.url, document = entry.document, snapshot = edit
        let style = edit.focusStyle ?? AutoFocusStyle()
        do {
            let events = try await Task.detached(priority: .userInitiated) { try EditStorage.events(in: url, document: document) }.value
            guard !closed, edit.hasSameMedia(as: snapshot), edit.focuses.first(where: { $0.id == id }) == segment else { return }
            var input = segment; input.start = segment.editingStart
            let following = AutoFocus.following(input, events: events, style: style)
            commit { edit in if let index = edit.focuses.firstIndex(where: { $0.id == id }) { edit.focuses[index].path = following.path; edit.focuses[index].sampledPath = true; edit.focuses[index].automatic = false } }
        } catch { self.error = error.localizedDescription }
    }

    private func loadPointers() async throws -> PointerTimeline {
        if let pointers { return pointers }
        let url = entry.url, document = entry.document
        let loaded = try await Task.detached(priority: .userInitiated) { try ProjectMedia.loadPointers(url: url, document: document) }.value
        pointers = loaded
        return loaded
    }
    /// 没有可用播放项时的兜底：离线解码并合成当前时间的静帧。串行处理，只保留最后一次请求。
    func refreshFallbackFrame() {
        fallbackRevision &+= 1
        guard edit.duration > 0, ready, !closed else { pendingFallback = nil; return }
        pendingFallback = (fallbackRevision, edit, skimPosition ?? position, false)
        if posterTask == nil { runFallbackWorker() }
    }

    /// 请求自带 `force`：为 true 时不受"播放项已就绪"限制——裁剪边缘超出当前播放项范围时也要显示。
    private func runFallbackWorker() {
        posterTask = Task { [weak self] in
            guard let self else { return }
            defer { posterTask = nil }
            while let request = pendingFallback, !Task.isCancelled, !closed {
                pendingFallback = nil
                do {
                    let image = try await previewRenderer.render(url: entry.url, document: entry.document, edit: request.edit, time: request.time)
                    try Task.checkCancellation()
                    // 过期画面不覆盖新位置；播放项已就绪时也不再用静帧盖住播放器输出。
                    if request.revision == fallbackRevision, !closed, request.force || loading || rebuilding || player.currentItem == nil { canvas.present(image: image) }
                } catch is CancellationError {} catch {
                    if request.revision == fallbackRevision, !closed { self.error = error.localizedDescription }
                }
            }
        }
    }
    /// 拖动过程中的每一步：画布参数、镜头、人像、音量直接换到播放项上，立即可见可听；
    /// 裁剪 / 拖边这类片段变化不重建播放项，只把正在拖动的边缘那一帧送到画布（`edgeSource`），
    /// 松手时才重建一次。结束后只保存一次编辑命令。
    func previewChanged(edgeSource: Double? = nil, edgeClip: UUID? = nil) {
        guard let previous = interactionStart else { return }
        if previous.clips != edit.clips || previous.layout != edit.layout || previous.focuses != edit.focuses || previous.focusStyle != edit.focusStyle || previous.automaticFocus != edit.automaticFocus || previous.camera != edit.camera || previous.pointer != edit.pointer {
            interactionChangesVisual = true
        }
        if !previous.hasSameMedia(as: edit) {
            if let edgeSource { presentSourceFrame(edgeSource, clip: edgeClip) }
            return
        }
        if !loading { refreshPresentation() }
    }

    /// 显示原素材某一帧：能映射到当前播放项就让播放器定位（硬件解码、无重建），否则离线渲染兜底。
    /// `clip` 指明正在裁剪的片段：素材被复制过时优先在这段里映射，镜头与光标状态才和松手后一致。
    func presentSourceFrame(_ source: Double, clip: UUID? = nil) {
        guard !closed else { return }
        player.pause(); playing = false; playAfterSeek = false
        skimPosition = nil
        edgePreview = (source, clip)
        if !loading, !rebuilding, player.currentItem != nil, let presented = presentedEdit, let time = presented.timelineTime(forSource: source, in: clip) {
            requestPlayerSeek(to: min(presented.duration, max(0, time)))
            return
        }
        fallbackRevision &+= 1
        guard let time = edit.timelineTime(forSource: source, in: clip) else { return }
        pendingFallback = (fallbackRevision, edit, min(edit.duration, max(0, time)), true)
        if posterTask == nil { runFallbackWorker() }
    }

    func export() {
        endInteraction()
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = entry.document.name + ".mp4"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let snapshot = edit, size = exportSize
        exporting = true; progress = 0; error = nil; exportedURL = nil
        exportTask = Task {
            defer { exporting = false; exportTask = nil }
            do {
                try await ProjectMedia.export(url: entry.url, document: entry.document, levels: snapshot.audio, destination: destination, edit: snapshot, longEdge: size) { self.progress = $0 }
                exportedURL = destination
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func cancelExport() { exportTask?.cancel() }
    func flush() -> Bool {
        endInteraction()
        if ready { save(); return saveStatus == "已保存" }
        return true
    }
    @discardableResult func close() -> Bool {
        guard !closed else { return true }
        guard flush() else { return false }
        closed = true
        canvas.detach()
        player.pause(); player.replaceCurrentItem(with: nil)
        if let observer { player.removeTimeObserver(observer) }; observer = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        reloadTask?.cancel(); analysisTask?.cancel(); exportTask?.cancel(); posterTask?.cancel(); seekTask?.cancel(); voiceProcessingTask?.cancel()
        pendingFallback = nil; pendingSeek = nil; playAfterSeek = false; edgePreview = nil; skimPosition = nil; rebuildingEdit = nil
        let renderer = previewRenderer
        Task { await renderer.close() }
        lease = nil; ready = false
        if VideoEditorSessions.current === self { VideoEditorSessions.current = nil }
        return true
    }
}

/// 保存失败时维持会话和内存编辑，窗口关闭与应用退出都必须先通过同一检查。
@MainActor
enum VideoEditorSessions {
    static var current: VideoEditorModel?
    static func closeCurrent(close: Bool = true) -> Bool {
        guard let current else { return true }
        guard (close ? current.close() : current.flush()) else {
            let alert = NSAlert()
            alert.messageText = "编辑尚未保存"
            alert.informativeText = "请检查磁盘空间和工程目录权限，然后重试保存。当前编辑仍保留在窗口中。"
            alert.runModal(); return false
        }
        return true
    }
}

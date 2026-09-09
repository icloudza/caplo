import SwiftUI
import AVFoundation

extension AVPlayer {
    /// 编辑器用的播放器：本地合成没有网络缓冲，不做“评估缓冲速率”的等待，起播就走。
    static func caploPlayer() -> AVPlayer {
        let player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = false
        return player
    }
}
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
    /// 播放器可以整个重建：录完一段后本进程的音频时钟偶尔起不来（HAL 报 stop、时间倒退、一直“评估缓冲”），换一个新播放器就好。
    private(set) var player = AVPlayer.caploPlayer()
    /// 一次卡住只重建一次，避免反复重建。
    private var recoveredFromStall = false
    /// 播放项失败要回报到界面：状态观察与“播到一半失败”通知，换播放项时重挂。
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemFailureObserver: NSObjectProtocol?
    @ObservationIgnored let canvas = CanvasPresenter()
    let audioTracks: Set<AudioTrack>
    var edit: VideoEdit
    var history = EditHistory()
    var selectedClip: UUID?
    var selectedClipIDs: Set<UUID> = []
    var selectedMedia: TimelineMedia?
    var selectedMediaID: UUID?
    var selectedFocus: UUID?
    var selectedMask: UUID?
    var selectedText: UUID?
    var selectedCaption: UUID?
    // MARK: 渲染副本

    /// 预编译跟随镜头的缓存键：只有这几项变了才需要重新规划运镜路径。
    /// 拿整份 `VideoEdit` 当键的话，拖一次遮罩就会重新规划一遍，白白卡住。
    private struct FocusPlanKey: Equatable {
        let clips: [VideoClip]
        let layerOrder: [UUID]?
        let focuses: [FocusSegment]
        let style: AutoFocusStyle?
        let automatic: Bool
    }
    @ObservationIgnored private var focusPlanKey: FocusPlanKey?
    @ObservationIgnored private var focusPlan: [FocusSegment]?
    /// 后台预解的指针事件，见 open()。构建播放项时也要用同一份，别在会话里存两份解析结果——
    /// 半小时的录制光指针事件就有几百万个采样。
    @ObservationIgnored private var pointerPreloadTask: Task<Void, Never>?

    /// 和画面同一份数据：跟随镜头已经预编译成运镜路径。
    ///
    /// `SceneInstruction` 在构建播放项时做的就是 `edit.resolvingTimelineFocus(events:)`，
    /// 所以画面用的相机来自这份副本。画布上的遮罩 / 文字编辑框如果拿 `edit` 去求相机，
    /// 跟随镜头一推近，框和画面就分家——手动加的跟随镜头在 `edit` 里只有静态 x/y/scale，
    /// 真正的运镜路径要到这一步才编译出来，两者能差 0.05 以上的归一化坐标。
    var renderEdit: VideoEdit {
        let key = FocusPlanKey(clips: edit.clips, layerOrder: edit.layerOrder, focuses: edit.focuses,
                               style: edit.focusStyle, automatic: edit.automaticFocus)
        if key != focusPlanKey {
            if pointers == nil {
                // 正常情况下 open() 里那次后台预解早已把它填好；这里是兜底（刚打开就立刻用到相机）。
                pointers = try? ProjectMedia.loadPointers(url: entry.url, document: entry.document)
            }
            focusPlan = edit.resolvingTimelineFocus(events: pointers?.focusSamples ?? []).focuses
            focusPlanKey = key
        }
        guard let focusPlan else { return edit }
        var result = edit
        result.focuses = focusPlan
        return result
    }

    /// 打字防抖的定时器。
    @ObservationIgnored private var textCommitTask: Task<Void, Never>?
    /// 遮罩面板打开时为真；画布上的遮罩编辑层只在这段时间接收鼠标，其余时候完全放行。
    var maskEditing = false
    /// 文字面板打开时为真，含义同上。
    var textEditing = false
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
            installTimeObserver()
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
            // 指针事件先在后台解出来。第一次访问 renderEdit 才去同步读盘的话，
            // 那一下往往正好落在鼠标事件里（画布命中测试就会取它），十分钟的录制能把界面卡住近百毫秒。
            let projectURL = entry.url, projectDocument = entry.document
            pointerPreloadTask = Task { [weak self] in
                let loaded = await Task.detached(priority: .utility) {
                    try? ProjectMedia.loadPointers(url: projectURL, document: projectDocument)
                }.value
                guard let self, !self.closed, self.pointers == nil, let loaded else { return }
                self.pointers = loaded
                // 之前若已经用空事件规划过，缓存要作废重排一次。
                self.focusPlanKey = nil
            }
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
        // 卡段文字紧跟它的定格片段：片段被拖边或删掉之后不能留下一段悬空的文字。
        edit.syncHoldCards()
        edit.normalizeTimelineRows()
        // 兜底：任何一条编辑路径把版本号写歪，都会在这里被按内容重新算对，
        // 而不是在校验时变成一句"版本不支持"甩给用户。
        edit.normalizeSchemaVersion()
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
        if !edit.maskList.contains(where: { $0.id == selectedMask }) { selectedMask = nil }
        if !edit.textList.contains(where: { $0.id == selectedText }) { selectedText = nil }
        if !edit.captionList.contains(where: { $0.id == selectedCaption }) { selectedCaption = nil }
        position = min(position, edit.duration)
        if let skimPosition { self.skimPosition = min(skimPosition, edit.duration) }
    }
    /// 距片段边缘不足最小时长时不能分割：工具栏按钮已禁用，快捷键则给出提示音而不是静默无效。
    var canSplit: Bool { canSplit(at: position) }
    /// 某个时间线时刻能否分割当前选中的块（两侧都要留下最小时长）；右键菜单用它判断"在此处分割"。
    func canSplit(at time: Double) -> Bool {
        guard ready, selectedFocus == nil, selectedMask == nil, time.isFinite else { return false }
        // 选中一句字幕时，「分割」指的是把这句切成两句，而不是切录制画面。
        if let selectedCaption, let cue = edit.caption(id: selectedCaption) {
            guard let source = edit.sourceTime(at: time) else { return false }
            return source > cue.sourceStart + 0.05 && source < cue.sourceEnd - 0.05
        }
        // 选中文字层时没有可分割的东西，别去切用户的录像。
        guard selectedText == nil else { return false }
        if let role = selectedMedia, let id = selectedMediaID, let clip = edit.mediaClips(role).first(where: { $0.id == id }) {
            let offset = time - (clip.timelineStart ?? 0)
            return offset >= VideoEdit.minimumClipDuration && clip.duration - offset >= VideoEdit.minimumClipDuration
        }
        if let id = selectedClip, let clip = edit.clips.first(where: { $0.id == id }) {
            // 定格卡段切不得：切完两半各自还是定格，可文字只认得其中一半。
            guard !edit.holdCards.contains(where: { $0.holdClipID == id }) else { return false }
            let offset = time - (clip.timelineStart ?? 0)
            return offset >= VideoEdit.minimumClipDuration && clip.duration - offset >= VideoEdit.minimumClipDuration
        }
        return false
    }
    func split() { split(at: position) }
    func split(at time: Double) {
        guard canSplit(at: time) else { NSSound.beep(); return }
        // 再守一道：分割只作用于媒体片段与字幕，绝不能借着常驻的 selectedClip 去切用户的录像。
        guard selectedMask == nil, selectedText == nil, selectedFocus == nil else { NSSound.beep(); return }
        if let selectedCaption, let source = edit.sourceTime(at: time) {
            var tail: UUID?
            commit { tail = $0.splitCaption(id: selectedCaption, atSource: source) }
            if let tail, edit.caption(id: tail) != nil { self.selectedCaption = tail }
            return
        }
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
    /// 清掉所有类别的选中项；换选一个别的东西时先调它，免得两处同时高亮。
    func clearSelection() {
        selectedMedia = nil; selectedMediaID = nil
        selectedFocus = nil; selectedMask = nil; selectedText = nil; selectedCaption = nil
    }
    func deleteSelection() {
        // 删卡段文字要连它插入的那段时长一起撤掉，否则成片里留下一段空白的定格。
        if let selectedText, edit.text(id: selectedText)?.holdClipID != nil {
            commit { $0.removeHoldCard(textID: selectedText) }; self.selectedText = nil; return
        }
        if let selectedCaption {
            commit { $0.captionList.removeAll { $0.id == selectedCaption } }; self.selectedCaption = nil; return
        }
        if let selectedText {
            commit { $0.removeText(id: selectedText) }; self.selectedText = nil; return
        }
        if let selectedMask {
            commit { $0.removeMask(id: selectedMask) }; self.selectedMask = nil; return
        }
        if let role = selectedMedia, let id = selectedMediaID {
            commit { edit in edit.setMediaClips(role, edit.mediaClips(role).filter { $0.id != id }) }
            selectedMedia = nil; selectedMediaID = nil; return
        }
        if let selectedFocus { commit { $0.focuses.removeAll { $0.id == selectedFocus } } }
        else {
            let ids = selectedClipIDs.isEmpty ? Set([selectedClip].compactMap { $0 }) : selectedClipIDs
            commit { edit in
                // 定格片段走卡段那条路：连同文字一起撤掉，后面的内容前移，而不是在成片里留一段空洞。
                for card in edit.holdCards where card.holdClipID.map(ids.contains) == true {
                    edit.removeHoldCard(textID: card.id)
                }
                edit.clips.removeAll { ids.contains($0.id) }
            }
        }
    }
    func selectClip(_ id: UUID, extending: Bool = false, range: Bool = false) {
        selectedMedia = nil; selectedMediaID = nil; selectedMask = nil; selectedText = nil; selectedCaption = nil
        if range, let selectedClip, let start = edit.clips.firstIndex(where: { $0.id == selectedClip }), let end = edit.clips.firstIndex(where: { $0.id == id }) {
            selectedClipIDs.formUnion(edit.clips[min(start, end)...max(start, end)].map(\.id))
        } else if extending {
            if selectedClipIDs.contains(id) { selectedClipIDs.remove(id) } else { selectedClipIDs.insert(id) }
            selectedClip = selectedClipIDs.contains(id) ? id : edit.clips.first(where: { selectedClipIDs.contains($0.id) })?.id
        } else { selectedClip = id; selectedClipIDs = [id] }
        selectedFocus = nil
    }
    /// 副本接在原件后面；接不下就贴着素材末尾放。不夹的话片尾附近复制会越界，
    /// 校验拒绝、整笔回滚，用户只看到一句「版本不支持或内容无效」。
    private func duplicatedStart(_ start: Double, duration: Double, pinned: Bool) -> Double {
        let limit = pinned ? max(edit.duration, duration) : entry.document.duration
        return max(0, min(start + duration, limit - duration))
    }
    func duplicateSelection() {
        if let id = selectedCaption, var copy = edit.caption(id: id) {
            copy.id = UUID()
            let length = copy.sourceDuration
            let next = duplicatedStart(copy.sourceStart, duration: length, pinned: copy.timelineStart != nil)
            let shift = next - copy.sourceStart
            copy.sourceStart = next; copy.sourceEnd = next + length
            copy.words = copy.words?.map { CaptionWord(start: $0.start + shift, end: $0.end + shift, text: $0.text) }
            if copy.timelineStart != nil { copy.timelineStart = (copy.timelineStart ?? 0) + length }
            commit { $0.captionList = ($0.captionList + [copy]).sorted { $0.sourceStart < $1.sourceStart } }
            selectedCaption = copy.id; return
        }
        if let id = selectedText, var copy = edit.text(id: id) {
            copy.id = UUID()
            // 副本不再是卡段：再插一段真实时长得由用户明说，不能一次 ⌘D 就把成片又拉长一截。
            copy.holdClipID = nil
            let next = duplicatedStart(copy.timelineStart ?? copy.start, duration: copy.duration, pinned: copy.timelineStart != nil)
            if copy.timelineStart != nil { copy.timelineStart = next } else { copy.start = next }
            commit { edit in edit.addText(copy); edit.moveLayer(copy.id, before: id) }
            selectedText = copy.id; return
        }
        if let id = selectedMask, var copy = edit.mask(id: id) {
            copy.id = UUID()
            let next = duplicatedStart(copy.timelineStart ?? copy.start, duration: copy.duration, pinned: copy.timelineStart != nil)
            // 关键帧的时间相对遮罩自身起点，副本整体挪走时它们跟着走，不需要额外平移。
            if copy.timelineStart != nil { copy.timelineStart = next } else { copy.start = next }
            commit { edit in edit.addMask(copy); edit.moveLayer(copy.id, before: id) }
            selectedMask = copy.id; return
        }
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
        guard let (anchor, length) = defaultFocusRange() else { return }
        addFocus(start: anchor, duration: length)
    }
    /// 播放头处默认镜头的范围：2 秒，不超出所在片段。
    private func defaultFocusRange() -> (Double, Double)? {
        guard let clip = edit.clips.first(where: { $0.id == selectedClip }) ?? edit.clip(atTimeline: position) else { return nil }
        let start = clip.timelineStart ?? 0
        let anchor = position >= start && position < start + clip.duration ? position : start
        return (anchor, min(2, start + clip.duration - anchor))
    }

    // MARK: 添加镜头前的重叠提示

    /// 等待用户确认的添加请求：这段时间里已经有镜头。
    struct PendingFocus: Identifiable, Equatable {
        let id = UUID()
        let start: Double
        let duration: Double
    }
    var pendingFocus: PendingFocus?
    static var defaults: UserDefaults = .standard
    static let overlapPromptSuppressedKey = "editor.focus.overlapPromptSuppressed"
    /// 这段时间内是否已有（显示着的）镜头。
    func focusOverlaps(start: Double, duration: Double) -> Bool {
        duration > 0 && !edit.focusSpans(in: start..<(start + duration)).isEmpty
    }
    /// 工具栏按钮：在播放头处添加，必要时先问。
    func requestAddFocus() {
        guard let (anchor, length) = defaultFocusRange() else { return }
        requestAddFocus(start: anchor, duration: length)
    }
    /// 添加镜头的统一入口：这段时间已有镜头且用户没勾过"不再提示"时先弹确认，否则直接加。
    func requestAddFocus(start: Double, duration: Double) {
        let start = max(0, min(edit.duration, start)), length = min(duration, edit.duration - start)
        guard length > 0 else { return }
        if focusOverlaps(start: start, duration: length), !Self.defaults.bool(forKey: Self.overlapPromptSuppressedKey) {
            pendingFocus = PendingFocus(start: start, duration: length)
        } else {
            addFocus(start: start, duration: length)
        }
    }
    func confirmPendingFocus(suppressFurtherPrompts: Bool) {
        guard let pending = pendingFocus else { return }
        pendingFocus = nil
        if suppressFurtherPrompts { Self.defaults.set(true, forKey: Self.overlapPromptSuppressedKey) }
        addFocus(start: pending.start, duration: pending.duration)
    }
    func cancelPendingFocus() { pendingFocus = nil }
    /// 在时间线任意范围添加跟随指针的手动镜头（不需要有点击事件）：范围落在单个片段内就关联该片段，
    /// 跨片段则不关联，让镜头顺着成片时间跟随下去。
    @discardableResult func addFocus(start: Double, duration: Double) -> UUID? {
        // 不在这里对齐帧格：播放头处添加沿用精确位置（旧行为），时间线拖出的范围由时间线自己按帧格对齐。
        let start = max(0, min(edit.duration, start))
        let length = min(duration, edit.duration - start)
        guard length > 0, let clip = edit.clip(atTimeline: start) else { return nil }
        let clipStart = clip.timelineStart ?? 0
        let within = start + length <= clipStart + clip.duration + 0.0001
        var zoom = FocusSegment(start: clip.sourceStart + min(start - clipStart, clip.playableDuration - 0.00001), duration: length, x: 0.5, y: 0.5,
                                scale: edit.focusStyle?.baseScale ?? AutoFocusStyle().baseScale)
        zoom.timelineStart = start; zoom.targetClipID = within ? clip.id : nil; zoom.followsTimeline = true
        zoom.easeIn = edit.focusStyle?.easeIn; zoom.easeOut = edit.focusStyle?.easeOut
        commit { edit in edit.focuses.append(zoom); edit.moveLayer(zoom.id, before: clip.id) }
        clearSelection(); selectedFocus = zoom.id
        return zoom.id
    }
    /// 在播放头处加一条遮罩，默认 2 秒且不超出所在片段。
    @discardableResult func addMask(kind: MaskSegment.Kind = .sensitive) -> UUID? {
        addMask(start: skimPosition ?? position, duration: 2, kind: kind)
    }
    /// 在指定时刻加遮罩。时间存回源素材域，之后剪辑素材它自己会跟着裂开与合拢。
    @discardableResult func addMask(start: Double, duration: Double, kind: MaskSegment.Kind = .sensitive) -> UUID? {
        guard ready else { return nil }
        let anchor = max(0, min(edit.duration, start))
        var length = duration
        if let clip = edit.clip(atTimeline: anchor) {
            length = min(length, (clip.timelineStart ?? 0) + clip.duration - anchor)
        }
        var created: UUID?
        commit { edit in
            created = edit.insertMask(at: anchor, duration: max(1.0 / 30, length), kind: kind, sourceDuration: entry.document.duration)
            if let created { edit.moveLayer(created, before: edit.orderedLayerIDs.first) }
        }
        guard let created, edit.mask(id: created) != nil else {
            if edit.clip(atTimeline: anchor) == nil { error = "播放头不在任何录制画面上，请先把它移到画面块里再添加遮罩。" }
            return nil
        }
        clearSelection(); selectedMask = created
        return created
    }

    /// 在播放头处插入一段全屏卡段：画面冻结在这一刻、声音静音，文字浮在上面，成片因此变长。
    @discardableResult func addHoldCard(duration: Double = 3, preset: TextPreset = .title, text: String = "") -> UUID? {
        guard ready else { return nil }
        let anchor = max(0, min(edit.duration, skimPosition ?? position))
        var created: UUID?
        commit { edit in
            created = edit.insertHoldCard(at: anchor, duration: duration, sourceDuration: entry.document.duration,
                                          preset: preset, text: text, frameRate: entry.document.frameRate)
        }
        guard let created, edit.text(id: created) != nil else {
            if edit.clip(atTimeline: anchor) == nil { error = "播放头不在任何录制画面上，请先把它移到画面块里再插入卡段。" }
            return nil
        }
        clearSelection(); selectedText = created
        return created
    }

    /// 打开 / 关掉某段全屏文字的「插入时长」。
    func setHoldCard(_ id: UUID, enabled: Bool) {
        guard ready else { return }
        var ok = false
        commit { ok = $0.setHoldCard(textID: id, enabled: enabled, sourceDuration: entry.document.duration, frameRate: entry.document.frameRate) }
        if !ok, enabled { error = "这段文字所在的位置插不进卡段，请把它移到某个录制画面块上再试。" }
    }

    /// 在播放头处加一段文字。
    @discardableResult func addText(preset: TextPreset = .title) -> UUID? {
        addText(start: skimPosition ?? position, duration: 3, preset: preset)
    }
    /// 在指定时刻加文字。时间存回源素材域，之后剪辑素材它自己会跟着裂开与合拢。
    @discardableResult func addText(start: Double, duration: Double, preset: TextPreset = .title, text: String = "") -> UUID? {
        guard ready else { return nil }
        let anchor = max(0, min(edit.duration, start))
        var length = duration
        if let clip = edit.clip(atTimeline: anchor) {
            length = min(length, (clip.timelineStart ?? 0) + clip.duration - anchor)
        }
        var created: UUID?
        commit { edit in
            created = edit.insertText(at: anchor, duration: max(0.2, length), sourceDuration: entry.document.duration, preset: preset, text: text)
            if let created { edit.moveLayer(created, before: edit.orderedLayerIDs.first) }
        }
        guard let created, edit.text(id: created) != nil else {
            if edit.clip(atTimeline: anchor) == nil { error = "播放头不在任何录制画面上，请先把它移到画面块里再添加文字。" }
            return nil
        }
        clearSelection(); selectedText = created
        return created
    }

    /// 打字期间只改预览；停手 0.6 秒后把这一整段输入合成一个撤销步骤。
    /// 逐字提交会让撤销栈里全是单字，撤三十次才回到上一句。
    func scheduleTextCommit() {
        beginInteraction()
        textCommitTask?.cancel()
        textCommitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.textCommitTask = nil
            self.endInteraction()
        }
    }

    // MARK: 字幕

    /// 转写进度；非空表示正在转写。
    private(set) var transcription: (progress: Double, message: String)?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    /// 转写用的语言；默认跟随系统。
    var captionLocale = Locale(identifier: Locale.preferredLanguages.first ?? "zh-CN")
    /// 转写用哪条声音；默认有麦克风就用麦克风。
    var captionSource: TranscriptionSource = .microphone
    /// 字幕面板打开时为真。
    var captionEditing = false

    var hasTranscribableAudio: Bool {
        TranscriptionSource.allCases.contains { ProjectTranscription.hasAudio(entry.document, source: $0) }
    }

    /// 转写整段录音。已有的、用户改过的句子会被保护住。
    func transcribe() {
        guard ready, transcriptionTask == nil else { return }
        var source = captionSource
        if !ProjectTranscription.hasAudio(entry.document, source: source) {
            source = TranscriptionSource.allCases.first { ProjectTranscription.hasAudio(entry.document, source: $0) } ?? source
            captionSource = source
        }
        guard ProjectTranscription.hasAudio(entry.document, source: source) else {
            error = TranscriptionError.noAudio.localizedDescription; return
        }
        let engine = SpeechTranscriber()
        let locale = captionLocale, url = entry.url, document = entry.document
        transcription = (0, "正在准备…")
        transcriptionTask = Task { @MainActor [weak self] in
            defer { self?.transcriptionTask = nil; self?.transcription = nil }
            switch await engine.availability(locale: locale) {
            case .ready: break
            case .needsPermission:
                guard await SpeechTranscriber.requestPermission() else {
                    self?.error = TranscriptionError.denied.localizedDescription; return
                }
            case .unavailable(let reason):
                self?.error = reason; return
            }
            guard let self, !Task.isCancelled else { return }
            self.transcription = (0, "正在转写…")
            do {
                let cues = try await ProjectTranscription.run(url: url, document: document, source: source,
                                                              locale: locale, engine: engine) { value in
                    Task { @MainActor [weak self] in
                        guard self?.transcriptionTask != nil else { return }
                        self?.transcription = (value, "正在转写…")
                    }
                }
                guard !Task.isCancelled else { return }
                self.commit { $0.mergeTranscription(cues) }
                if cues.isEmpty { self.error = "这段声音里没有识别出可用的语音。" }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
    func cancelTranscription() {
        transcriptionTask?.cancel(); transcriptionTask = nil; transcription = nil
    }

    /// 导入 SRT / VTT。时间按成片时间换算回源时间，导入的句子一律锁住。
    func importCaptions(from url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            error = "读不出这个字幕文件，请确认它是 UTF-8 编码的 SRT 或 VTT。"; return
        }
        let cues = CaptionFile.parse(text, into: edit)
        guard !cues.isEmpty else { error = "这个字幕文件里没有可用的句子，或者它们都落在已经剪掉的画面上。"; return }
        // 导入的内容说了算：与它重叠的旧句子让位，不重叠的保留。
        // 反过来做会让同一段话变成两条，导出时每句输出两遍。
        commit { $0.mergeImportedCaptions(cues) }
    }

    /// 导出 SRT / VTT 的文本；调用方负责写文件。
    func captionFileText(vtt: Bool) -> String { vtt ? CaptionFile.vtt(edit) : CaptionFile.srt(edit) }

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
    private func installTimeObserver() {
        if let observer { player.removeTimeObserver(observer) }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                // 暂停定位时播放器回调可能仍是旧时间，不能覆盖用户正在拖动的播放头；重建中旧播放项的时间线已失效。
                guard self.playing, self.seekTask == nil, !self.loading, !self.rebuilding else { return }
                if time.seconds.isFinite { self.position = min(self.edit.duration, max(0, time.seconds)) }
                self.playing = self.player.rate != 0
                if self.playing { self.recoveredFromStall = false }
            }
        }
    }

    /// 播放器起不来时整个换新：新的 AVPlayer 会重新绑定音频设备时钟；播放项按当前编辑重建，重建完成后从原位置起播。
    private func replacePlayerAndRetry() {
        let stalled = player
        stalled.pause(); stalled.replaceCurrentItem(with: nil)
        if let observer { stalled.removeTimeObserver(observer) }; observer = nil
        canvas.attach(item: nil); presentedEdit = nil
        player = AVPlayer.caploPlayer()
        installTimeObserver()
        playAfterSeek = true
        reload()
    }

    /// 播放项状态变成失败、或播到一半失败：把原因写进界面与日志，按钮回到未播放。没有这层，播放失败就是“点了没反应”。
    private func observeFailures(of item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.reportPlaybackFailure(item.error, stage: "播放项就绪失败") }
        }
        if let itemFailureObserver { NotificationCenter.default.removeObserver(itemFailureObserver) }
        itemFailureObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in self?.reportPlaybackFailure(error, stage: "播放中断") }
        }
    }
    private func reportPlaybackFailure(_ failure: Error?, stage: String) {
        let nsError = failure as NSError?
        let underlying = (nsError?.userInfo[NSUnderlyingErrorKey] as? NSError).map { "，底层 \($0.domain) \($0.code)" } ?? ""
        let detail = nsError.map { "\($0.localizedDescription)（\($0.domain) \($0.code)\(underlying)）" } ?? "没有错误详情"
        NSLog("Caplo：%@：%@", stage, detail)
        error = stage + "：" + (nsError?.localizedDescription ?? "未知原因")
        playing = false; playAfterSeek = false
    }

    func togglePlayback() {
        if playing || playAfterSeek { pause(); return }
        if let item = player.currentItem, item.status == .failed { reportPlaybackFailure(item.error, stage: "播放项就绪失败"); return }
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
        else {
            player.playImmediately(atRate: 1); playing = true
            if let item = player.currentItem, item.status != .readyToPlay { NSLog("Caplo：起播时播放项状态 %d（0 未知 / 2 失败），播放器错误：%@", item.status.rawValue, player.error?.localizedDescription ?? "无") }
            watchPlaybackStall()
        }
    }
    /// 起播 2 秒后播放器还在“等待”（画面出不来、素材读不到）就把原因写进界面与日志，不让用户对着不动的画面猜。
    private func watchPlaybackStall() {
        let started = player.currentTime().seconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, playing, !closed else { return }
            let now = player.currentTime().seconds
            guard now - started < 0.2 else { return }
            let reason = player.reasonForWaitingToPlay?.rawValue ?? "无"
            let status = player.currentItem?.status.rawValue ?? -1
            NSLog("Caplo：起播 2 秒画面没动：时间 %.2f → %.2f，控制状态 %d，等待原因 %@，播放项状态 %d，错误 %@", started, now, player.timeControlStatus.rawValue, reason, status,
                  (player.currentItem?.error ?? player.error)?.localizedDescription ?? "无")
            // 播放项本身就绪却不动：本进程的播放器时钟坏了（录完一段后常见），换一个新播放器重来一次。
            if status == AVPlayerItem.Status.readyToPlay.rawValue, !recoveredFromStall {
                recoveredFromStall = true
                NSLog("Caplo：换新播放器重试")
                replacePlayerAndRetry()
                return
            }
            if error == nil { error = "播放器起播后画面没有前进（等待原因：\(reason)）；请把日志里“Caplo：”开头的几行发来。" }
        }
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
                observeFailures(of: item)
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
        if edit.differsVisually(from: previous) {
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
        exporting = true; progress = 0; error = nil
        exportTask = Task {
            defer { exporting = false; exportTask = nil }
            do {
                try await ProjectMedia.export(url: entry.url, document: entry.document, levels: snapshot.audio, destination: destination, edit: snapshot, longEdge: size) { self.progress = $0 }
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
        pointerPreloadTask?.cancel(); pointerPreloadTask = nil
        // 转写与打字防抖也要停：关窗之后它们还在读这份工程，用户此刻已经可以去删它了。
        transcriptionTask?.cancel(); transcriptionTask = nil; transcription = nil
        textCommitTask?.cancel(); textCommitTask = nil
        // 播放项的观察者不摘掉，播放器换过之后仍会回调进一个已经关掉的会话。
        itemStatusObservation?.invalidate(); itemStatusObservation = nil
        if let itemFailureObserver { NotificationCenter.default.removeObserver(itemFailureObserver) }; itemFailureObserver = nil
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

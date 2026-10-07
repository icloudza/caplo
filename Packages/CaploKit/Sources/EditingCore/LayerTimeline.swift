import Foundation

/// 每个媒体块独立定位；旧工程在第一次编辑时展开，保留原来的音画对应关系。
public enum TimelineMedia: String, Sendable { case screen, camera, system, microphone }

extension VideoEdit {
    public func mediaClips(_ role: TimelineMedia) -> [VideoClip] {
        // 旧工程的声音轨没有独立列表时跟着画面片段走；卡片没有声音，不能被当成一段声音带过去。
        switch role { case .screen: orderedScreenClips; case .camera: orderedCameraClips; case .system: systemClips ?? mediaOnlyClips; case .microphone: microphoneClips ?? mediaOnlyClips }
    }
    /// 这条轨有没有自己单独的一份片段。声音轨默认没有（nil）：跟着画面片段走，切开、拖边、删除、插卡片都自动一致，
    /// 播放与导出按画面片段的可见段取声音（`resolvedMedia`）。只有用户"分离声音"之后才有自己的一份。
    /// 逐轨处理片段的地方（切开、平移、合并）一律先问它：对跟随画面的轨调 `setMediaClips` 会把它悄悄拆出来。
    public func ownsTrack(_ role: TimelineMedia) -> Bool {
        switch role { case .screen: true; case .camera: cameraClips != nil; case .system: systemClips != nil; case .microphone: microphoneClips != nil }
    }
    public func audioFollowsPicture(_ role: TimelineMedia) -> Bool { (role == .system || role == .microphone) && !ownsTrack(role) }

    /// 分离声音：声音轨各复制一份画面片段（新 ID，带着各块音量），之后可以单独拖动、剪辑。
    public mutating func detachAudio() {
        materializeLayers()
        var added: [UUID] = []
        for role in [TimelineMedia.system, .microphone] where !ownsTrack(role) {
            let copies = mediaOnlyClips.map { clip -> VideoClip in
                var copy = clip; copy.id = UUID(); copy.title = nil; copy.cursorHidden = false; return copy
            }
            added += copies.map(\.id)
            setMediaClips(role, copies)
        }
        // 层序：声音放在最底下，与新工程的默认行序一致。
        if !added.isEmpty, var order = layerOrder { order.removeAll { added.contains($0) }; order += added; layerOrder = order }
        audioDetached = true
        normalizeTimelineRows()
    }
    /// 声音跟随画面：丢掉单独剪过的声音轨，回到跟着画面片段走。各画面片段的单块音量取它开头那一刻所在声音块的音量。
    public mutating func attachAudio() {
        for role in [TimelineMedia.system, .microphone] where ownsTrack(role) {
            let own = mediaClips(role), index = TimelineIndex(clips: own)
            for number in clips.indices where clips[number].card == nil {
                guard let hit = index.clipIndex(at: clips[number].timelineStart ?? 0) else { continue }
                if role == .system { clips[number].systemGain = own[hit].systemGain } else { clips[number].microphoneGain = own[hit].microphoneGain }
            }
            let ids = Set(own.map(\.id))
            layerOrder?.removeAll { ids.contains($0) }
            rowGroups = rowGroups?.map { $0.filter { !ids.contains($0) } }.filter { !$0.isEmpty }
            if role == .system { systemClips = nil } else { microphoneClips = nil }
        }
        audioDetached = nil
        normalizeTimelineRows()
    }
    /// 旧工程打开时：声音轨跟画面片段一一对得上（位置、源起点、长度都没动过），说明从没单独剪过，
    /// 收回成跟随画面，单块音量挪到对应的画面片段上。用户明确分离过的（`audioDetached`）不收。
    mutating func collapseUnchangedAudio() {
        guard audioDetached != true else { return }
        let picture = mediaOnlyClips.sorted { ($0.timelineStart ?? 0) < ($1.timelineStart ?? 0) }
        for role in [TimelineMedia.system, .microphone] where ownsTrack(role) {
            let own = (role == .system ? systemClips : microphoneClips) ?? []
            // 没录到这条声音的工程存的是空列表：保持原样（没有可跟随的声音）。
            guard !own.isEmpty, own.count == picture.count else { continue }
            let sorted = own.sorted { ($0.timelineStart ?? 0) < ($1.timelineStart ?? 0) }
            let same = zip(sorted, picture).allSatisfy { a, b in
                abs((a.timelineStart ?? 0) - (b.timelineStart ?? 0)) < 0.0005 && abs(a.sourceStart - b.sourceStart) < 0.0005
                    && abs(a.duration - b.duration) < 0.0005 && abs(a.playableDuration - b.playableDuration) < 0.0005
            }
            guard same else { continue }
            for (audio, clip) in zip(sorted, picture) {
                guard let number = clips.firstIndex(where: { $0.id == clip.id }) else { continue }
                if role == .system { clips[number].systemGain = audio.systemGain } else { clips[number].microphoneGain = audio.microphoneGain }
            }
            let ids = Set(own.map(\.id))
            layerOrder?.removeAll { ids.contains($0) }
            rowGroups = rowGroups?.map { $0.filter { !ids.contains($0) } }.filter { !$0.isEmpty }
            if role == .system { systemClips = nil } else { microphoneClips = nil }
        }
    }

    /// 去掉卡片之后的画面片段：声音、人像轨按旧规则"跟随画面"时只能跟随真正引用素材的片段。
    var mediaOnlyClips: [VideoClip] {
        clips.contains { $0.card != nil } ? clips.filter { $0.card == nil } : clips
    }
    public mutating func setMediaClips(_ role: TimelineMedia, _ values: [VideoClip]) {
        switch role { case .screen: clips = values; case .camera: cameraClips = values; case .system: systemClips = values; case .microphone: microphoneClips = values }
        normalizeTimelineRows()
    }
    /// 给时间线上的块（任一媒体片段或镜头）起名；空白视为清除，恢复默认名称。
    public mutating func renameBlock(_ id: UUID, title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.flatMap { $0.isEmpty ? nil : $0 }
        if let index = focuses.firstIndex(where: { $0.id == id }) { focuses[index].title = value; return }
        if maskList.contains(where: { $0.id == id }) { updateMask(id: id) { $0.title = value }; return }
        if textList.contains(where: { $0.id == id }) { updateText(id: id) { $0.title = value }; return }
        for role in [TimelineMedia.screen, .camera, .system, .microphone] {
            var values = role == .screen ? clips : mediaClips(role)
            guard let index = values.firstIndex(where: { $0.id == id }) else { continue }
            values[index].title = value
            switch role { case .screen: clips = values; case .camera: cameraClips = values; case .system: systemClips = values; case .microphone: microphoneClips = values }
            return
        }
    }
    public mutating func materializeLayers() {
        let index = TimelineIndex(clips: clips)
        for number in clips.indices { clips[number].timelineStart = index.boundaries[number] }
        // 只展开人像轨；声音轨默认跟随画面，不在这里拆出来（见 `ownsTrack`）。
        if cameraClips == nil { setMediaClips(.camera, mediaOnlyClips.map { var copy = $0; copy.id = UUID(); return copy }) }
    }
    /// 画面会不会不一样。**除了音量之外的任何差别都算**——这条判定必须是"反过来"写的：
    /// 逐个列举"哪些字段影响画面"的写法每加一个新图层就漏一次，而且漏了完全没有报错，
    /// 只表现为编辑器里改了没反应、导出却是对的（遮罩和字幕都各踩过一次）。
    public func differsVisually(from other: VideoEdit) -> Bool {
        var candidate = other
        candidate.audio = audio
        return candidate != self
    }
    public func hasSameMedia(as other: VideoEdit) -> Bool {
        // 语音处理开关换的是麦克风素材文件本身，也算素材变化（要重建播放项）。
        // 卡片的文字与背景是合成器画的，改它们不用重建播放项（逐字重建会让打字时画面一闪一闪）；
        // 卡片的增删、时长、位置仍算素材变化。
        // 层序只比素材块那一部分：文字、遮罩、镜头的层序只决定画面怎么叠，不改变素材怎么拼接。
        // 以前整份层序一起比，加一条文字或遮罩（会往层序里插一个 ID）就整个重建播放项，大工程每次要等好几秒。
        // 单块音量也不算：它只改混音参数，播放项上换一份 audioMix 就行（见 `gainSignature`）；
        // 以前拖一下"这一块的音量"滑条，每一帧都要整个重建播放项。
        mediaLayerOrder == other.mediaLayerOrder && Self.mediaShape(clips) == Self.mediaShape(other.clips) && cameraClips == other.cameraClips
            && (systemClips == nil) == (other.systemClips == nil) && Self.mediaShape(systemClips ?? []) == Self.mediaShape(other.systemClips ?? [])
            && (microphoneClips == nil) == (other.microphoneClips == nil) && Self.mediaShape(microphoneClips ?? []) == Self.mediaShape(other.microphoneClips ?? [])
            && duration == other.duration && audio.voiceProcessing == other.audio.voiceProcessing
    }
    /// 所有片段的单块音量，按轨依次排开：变了就要换一份混音参数。
    public var gainSignature: [Float] {
        [clips, systemClips ?? [], microphoneClips ?? []].flatMap { $0.flatMap { [$0.systemGain, $0.microphoneGain] } }
    }
    /// 层序里属于素材块（画面、人像、两条声音）的那些 ID，保持原顺序；没有层序时为 nil。
    var mediaLayerOrder: [UUID]? {
        guard let layerOrder else { return nil }
        var media = Set(clips.map(\.id))
        for values in [cameraClips, systemClips, microphoneClips] { media.formUnion((values ?? []).map(\.id)) }
        return layerOrder.filter(media.contains)
    }
    /// 比较素材用的片段列表：卡片只留"它在这里、多长"，内容抹掉。
    static func mediaShape(_ values: [VideoClip]) -> [VideoClip] {
        guard values.contains(where: { $0.card != nil || $0.systemGain != 1 || $0.microphoneGain != 1 }) else { return values }
        return values.map { clip in
            var copy = clip; copy.systemGain = 1; copy.microphoneGain = 1
            guard clip.card != nil else { return copy }
            copy.card = TitleCard(text: TextSegment(start: 0, duration: 1)); copy.title = nil
            return copy
        }
    }
    /// 只改变选中块的起止，不推挤相邻图层；左边缘受源起点限制，右边缘可进入末帧保持区。
    public mutating func dragMedia(_ role: TimelineMedia, id: UUID, edge: FocusDragEdge, delta: Double, sourceDuration: Double) {
        guard delta.isFinite else { return }
        materializeLayers()
        var values = role == .screen ? clips : mediaClips(role)
        guard let number = values.firstIndex(where: { $0.id == id }) else { return }
        var clip = values[number]
        let start = clip.timelineStart ?? 0, minimum = Self.minimumClipDuration
        // 卡片不引用素材，下面两个分支按"源里还剩多少"重算 mediaDuration 对它没有意义。
        // 拖右缘就是改卡片时长，后面的内容跟着挪；左缘没有对应语义，不动。
        if clip.card != nil {
            switch edge {
            case .body: break
            case .leading: return
            case .trailing: setCardDuration(id: id, duration: clip.duration + delta); return
            }
        }
        switch edge {
        case .body: clip.timelineStart = max(0, start + delta)
        case .leading:
            let change = min(clip.duration - minimum, max(-min(start, clip.sourceStart), delta))
            clip.timelineStart = start + change; clip.sourceStart += min(change, clip.playableDuration - 0.00001)
            clip.duration -= change
            clip.mediaDuration = min(clip.duration, max(0.00001, sourceDuration - clip.sourceStart))
        case .trailing:
            clip.duration = max(minimum, clip.duration + delta)
            clip.mediaDuration = min(clip.duration, max(0.00001, sourceDuration - clip.sourceStart))
        }
        values[number] = clip; setMediaClips(role, values)
        if role == .screen, edge == .body {
            let shift = (clip.timelineStart ?? 0) - start
            for number in focuses.indices where focuses[number].targetClipID == id {
                focuses[number].timelineStart = max(0, focuses[number].editingStart + shift)
            }
        }
    }
    /// 分割作为一次原子编辑同时安排新块行序，返回稳定 ID，调用方不应通过排序后的数组猜测尾块。
    @discardableResult public mutating func splitMedia(_ role: TimelineMedia, id: UUID, at time: Double) -> UUID? {
        var values = role == .screen ? clips : mediaClips(role); let index = TimelineIndex(clips: values)
        guard time.isFinite, let number = values.firstIndex(where: { $0.id == id }) else { return nil }
        let clip = values[number], offset = time - index.boundaries[number]
        guard offset >= Self.minimumClipDuration, clip.duration - offset >= Self.minimumClipDuration else { return nil }
        // 卡片切不得：切开的两块卡片各自带着同一段文字，一段话被拆成两次进出场，没有意义。
        guard clip.card == nil else { return nil }
        let previousOrder = orderedLayerIDs
        // 只看用户显式指定的行：自动排出来的行不该因为切一刀就被写死成显式行，
        // 那样以后新加的同类块就再也并不进来了。头在显式行里，尾就跟着进去；
        // 否则尾块由自动排行接管——同类、不重叠，本来就会落回同一行。
        let previousGroups = rowGroups ?? []
        let splitSharesRow = previousGroups.contains { $0.contains(id) }
        var copiedFocusSources: [UUID: UUID] = [:]
        var tail = clip; tail.id = UUID(); tail.duration = clip.duration - offset
        tail.sourceStart += min(offset, clip.playableDuration - 0.00001)
        if clip.timelineStart != nil { tail.timelineStart = time }
        if clip.mediaDuration != nil { tail.mediaDuration = max(0.00001, clip.playableDuration - offset) }
        values[number].duration = offset
        if clip.mediaDuration != nil { values[number].mediaDuration = min(offset, clip.playableDuration) }
        values.insert(tail, at: number + 1); setMediaClips(role, values)
        if role == .screen, clip.timelineStart != nil {
            // 智能镜头跨剪切保持一个连续块；旧固定 / 烘焙效果仍分割并保留动画相位。
            var copies: [FocusSegment] = []
            for position in focuses.indices where focuses[position].targetClipID == id {
                let focus = focuses[position], end = focus.editingStart + focus.duration
                if focus.editingStart >= time { focuses[position].targetClipID = tail.id }
                else if end > time {
                    if focus.followsTimeline == true {
                        focuses[position].targetClipID = nil
                        continue
                    }
                    var copy = focus; copy.id = UUID(); copy.timelineStart = time; copy.duration = end - time; copy.targetClipID = tail.id
                    copy.transitionDuration = focus.transitionDuration ?? focus.duration
                    copy.transitionOffset = (focus.transitionOffset ?? 0) + time - focus.editingStart
                    focuses[position].duration = time - focus.editingStart
                    focuses[position].transitionDuration = focus.transitionDuration ?? focus.duration
                    focuses[position].transitionOffset = focus.transitionOffset ?? 0
                    copiedFocusSources[copy.id] = focus.id
                    copies.append(copy)
                }
            }
            focuses += copies
        }
        if clip.timelineStart != nil {
            // 新尾块放在原块上方，两侧关联效果分别紧贴各自素材。仅整理此次分割涉及的组，
            // 其他媒体与效果保留相对顺序；旧连续剪辑不创建行序，避免改变其拼接语义。
            let ranks = Dictionary(uniqueKeysWithValues: previousOrder.enumerated().map { ($0.element, $0.offset) })
            let linked = role == .screen ? focuses.filter { $0.targetClipID == id || $0.targetClipID == tail.id } : []
            let headEffects = linked.filter { $0.targetClipID == id }.sorted { (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max) }.map(\.id)
            let tailEffects = linked.filter { $0.targetClipID == tail.id }.sorted {
                (ranks[copiedFocusSources[$0.id] ?? $0.id] ?? Int.max) < (ranks[copiedFocusSources[$1.id] ?? $1.id] ?? Int.max)
            }.map(\.id)
            let affected = Set(headEffects + tailEffects + [id, tail.id])
            // 以原素材的位置作锚点；即使用户把关联效果移到远处，也不能把素材整组搬过去。
            let anchor = previousOrder.firstIndex(of: id) ?? previousOrder.count
            let insertion = previousOrder.prefix(anchor).filter { !affected.contains($0) }.count
            var order = previousOrder.filter { !affected.contains($0) }
            order.insert(contentsOf: tailEffects + [tail.id] + headEffects + [id], at: insertion)
            layerOrder = order
        }
        if !previousGroups.isEmpty {
            // 已同行的素材分割后继续共行；已有聚焦若与其他块同行，其动画副本也保留该行。
            rowGroups = previousGroups.map { group in
                let members = Set(group)
                return group + (members.contains(id) ? [tail.id] : []) + copiedFocusSources.compactMap { members.contains($0.value) ? $0.key : nil }
            }
            normalizeTimelineRows()
            layerOrder = timelineRows.flatMap { $0 }
            if splitSharesRow, role == .screen {
                // 新关联效果位于目标整行上方，不能夹在同行成员之间；按整行搬动以保留其他分组。
                let linked = Set(focuses.filter { $0.targetClipID == id || $0.targetClipID == tail.id }.map(\.id))
                let rows = timelineRows
                if let target = rows.firstIndex(where: { $0.contains(id) }) {
                    let effectRows = Set(rows.indices.filter { $0 != target && rows[$0].contains(where: linked.contains) })
                    let insertion = rows.indices.prefix(target).filter { !effectRows.contains($0) }.count
                    var remaining = rows.enumerated().filter { $0.offset != target && !effectRows.contains($0.offset) }.map(\.element)
                    let effects = rows.indices.filter { effectRows.contains($0) }.map { rows[$0] }
                    remaining.insert(contentsOf: effects + [rows[target]], at: insertion)
                    layerOrder = remaining.flatMap { $0 }
                }
            }
            normalizeTimelineRows()
        }
        return tail.id
    }

    /// 将遮挡关系解析为不重叠的素材切片；播放和导出用同一结果，空白区间保留。
    public func resolvedMedia(_ role: TimelineMedia) -> [VideoClip] {
        let values = mediaClips(role), index = TimelineIndex(clips: values)
        return index.spans.map { span in
            var clip = values[span.index]
            let offset = span.start - index.boundaries[span.index]
            let available = clip.playableDuration
            clip.timelineStart = span.start; clip.duration = span.end - span.start
            clip.sourceStart += min(offset, available - 0.00001)
            clip.mediaDuration = max(0, min(clip.duration, available - offset))
            return clip
        }
    }
}

/// 统一行顺序使用稳定 ID，排序不改变块的时间或效果所关联的素材。
extension VideoEdit {
    public mutating func prepareLayerEditing(camera availableCamera: Bool, system: Bool, microphone: Bool) {
        normalizeSchemaVersion(layered: true)
        materializeLayers()
        collapseUnchangedAudio()
        // 没录到的声音存空列表（与"跟随画面"区分开：没有可跟随的声音）。
        if !availableCamera { cameraClips = [] }; if !system { systemClips = [] }; if !microphone { microphoneClips = [] }
        let appearances = focusSpans()
        for span in appearances { materializeFocus(span) }
        if layerOrder == nil {
            // 默认行序：镜头与录制画面在上，摄像头行紧贴在声音轨上方（不放最顶端），最后是系统声音、麦克风。
            // 行序只描述编辑器布局；摄像头画中画始终叠在画面之上，不随行序改变。
            // 文字与遮罩行放在最顶端：它们盖在所有画面之上，行序也照这个直觉排。
            var order: [UUID] = textList.map(\.id) + maskList.map(\.id)
            let effectsByTarget = Dictionary(grouping: focuses.filter { $0.targetClipID != nil }, by: { $0.targetClipID! })
            for clip in clips.reversed() {
                order += (effectsByTarget[clip.id] ?? []).map(\.id)
                order.append(clip.id)
            }
            order += focuses.filter { $0.targetClipID == nil }.map(\.id)
            order += (cameraClips ?? []).map(\.id)
            order += (systemClips ?? []).map(\.id) + (microphoneClips ?? []).map(\.id)
            layerOrder = order
        } else {
            // 2026-09-08 起摄像头行默认在声音轨上方：老工程若仍是旧默认（摄像头行在最顶端、未与他行合并），迁到新位置；手动排过的顺序不动。
            let cameraIDs = (cameraClips ?? []).map(\.id)
            if !cameraIDs.isEmpty, var order = layerOrder, Array(order.prefix(cameraIDs.count)) == cameraIDs,
               !(rowGroups ?? []).contains(where: { group in group.contains(where: cameraIDs.contains) }) {
                order.removeFirst(cameraIDs.count)
                let audio = Set((systemClips ?? []).map(\.id) + (microphoneClips ?? []).map(\.id))
                let insertion = order.firstIndex(where: audio.contains) ?? order.count
                order.insert(contentsOf: cameraIDs, at: insertion)
                layerOrder = order
            }
            // 重新生成自动镜头会产生新 ID；已有工程也要把这些新行插到关联素材上方，
            // 不能依赖 orderedLayerIDs 的兜底追加而落到声音轨之后。保留旧行的手动排序。
            let existing = Set(layerOrder ?? [])
            var order = orderedLayerIDs
            // 新加的遮罩与文字要顶到最上面，不能靠 orderedLayerIDs 的兜底追加落到声音轨下面。
            for mask in maskList.reversed() where !existing.contains(mask.id) {
                order.removeAll { $0 == mask.id }; order.insert(mask.id, at: 0)
            }
            for value in textList.reversed() where !existing.contains(value.id) {
                order.removeAll { $0 == value.id }; order.insert(value.id, at: 0)
            }
            let rowHeads = rowGroups == nil ? [:] : Dictionary(uniqueKeysWithValues: timelineRows.flatMap { row in row.map { ($0, row[0]) } })
            for focus in focuses where !existing.contains(focus.id) {
                guard let target = focus.targetClipID, order.contains(target) else { continue }
                order.removeAll { $0 == focus.id }
                if let insertion = order.firstIndex(of: rowHeads[target] ?? target) { order.insert(focus.id, at: insertion) }
            }
            layerOrder = order
        }
        constrainTimelineFocuses()
        normalizeTimelineRows()
    }
    public mutating func moveLayer(_ id: UUID, before target: UUID?) {
        guard id != target else { return }
        guard orderedLayerIDs.contains(id) else { return }
        removeTimelineRowMember(id)
        var order = orderedLayerIDs
        order.removeAll { $0 == id }
        // 新聚焦默认独立成行，即使目标素材已同行，也插在其整行上方。
        let anchor = target.flatMap { target in rowGroups == nil ? target : timelineRows.first(where: { $0.contains(target) })?.first }
        let insertion = anchor.flatMap { order.firstIndex(of: $0) } ?? order.count
        order.insert(id, at: insertion); layerOrder = order
        normalizeTimelineRows()
    }
    public var orderedLayerIDs: [UUID] {
        let all = textList.map(\.id) + maskList.map(\.id) + clips.map(\.id) + focuses.map(\.id) + (cameraClips ?? []).map(\.id) + (systemClips ?? []).map(\.id) + (microphoneClips ?? []).map(\.id)
        let valid = Set(all), saved = (layerOrder ?? []).filter { valid.contains($0) }, existing = Set(saved)
        return saved + all.filter { !existing.contains($0) }
    }
    public var orderedCameraClips: [VideoClip] {
        let values = cameraClips ?? mediaOnlyClips
        guard let layerOrder, cameraClips != nil else { return values }
        let ranks = Dictionary(uniqueKeysWithValues: layerOrder.enumerated().map { ($0.element, $0.offset) })
        return values.sorted { (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max) }
    }
    public var orderedScreenClips: [VideoClip] {
        guard let layerOrder else { return clips }
        let ranks = Dictionary(uniqueKeysWithValues: layerOrder.enumerated().map { ($0.element, $0.offset) })
        return clips.sorted { (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max) }
    }
}

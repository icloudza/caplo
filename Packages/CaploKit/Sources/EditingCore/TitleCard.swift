import Foundation

/// 卡片：画面轨上一段自带内容的片段——背景加一段文字，用作片头、章节、片尾。
///
/// 2026-10-06 取代旧的"全屏卡段"。旧做法是"在插入点冻结一帧录屏 + 叠一段锁死为全屏的文字 + 人像轨也冻一帧"，
/// 可全屏版式会把画面淡到完全透明，那一帧定格在卡段中间根本看不见；为了让三样东西同生共死，
/// 编辑、拖动、删除各处写满特例，删掉之后插入时切开的口子还合不上。现在卡片就是画面轨上的一块：
/// 不引用素材、不绑文字层、不占人像轨，时间线上只有这一块，拖、删、复制都只对它。
///
/// 进出卡片时画面层缩小并淡出到背景（与全屏文字同一套版式变换，见 `VideoEdit.stage(at:spans:)`），
/// 卡片期间不画录屏、人像、光标、镜头与遮罩，声音轨在这一段留空。
public struct TitleCard: Codable, Equatable, Sendable {
    /// 卡片上的文字：排版、外观、进出场动画都沿用文字层（面板与渲染共用一套）。
    /// 时间由卡片片段决定——`start` / `timelineStart` / `duration` 在这里不读，渲染时按片段的起止重写；
    /// 版式固定为全屏，只为借用全屏的文字盒（版式变换由卡片自己负责，不经过这段文字）。
    public var text: TextSegment
    /// 背景色；nil 表示跟随画布背景（壁纸 / 渐变 / 纯色），与录制画面四周看到的一样。
    public var background: TextSegment.Palette?
    /// 插入卡片时为腾出位置切开的片段（各条轨的"原块 → 尾块"）。删卡片时两半若还挨着、源时间还连续，就合回一块，
    /// 不在时间线上留下一道插入前没有的切口。
    public var joins: [Join]?

    public struct Join: Codable, Equatable, Sendable {
        public var head: UUID
        public var tail: UUID
        public init(head: UUID, tail: UUID) { self.head = head; self.tail = tail }
    }

    public init(text: TextSegment? = nil, background: TextSegment.Palette? = nil) {
        var value = text ?? TextPreset.title.segment(start: 0, duration: VideoEdit.defaultCardDuration)
        if text == nil { value.text = String(localized: "标题") }
        value.start = 0; value.timelineStart = nil; value.holdClipID = nil
        value.layout = .fullscreen
        self.text = value
        self.background = background
    }

    /// 卡片的默认名：文字的第一行，没写字就叫"卡片"。
    public var defaultTitle: String {
        let line = text.text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? String(localized: "卡片") : String(trimmed.prefix(16))
    }

    var isValid: Bool {
        var probe = text
        probe.start = 0; probe.timelineStart = nil; probe.duration = max(probe.duration, 0.1)
        return probe.isValid && probe.holdClipID == nil && background?.isValid != false && (joins?.count ?? 0) <= 16
    }
}

extension VideoEdit {
    /// 新卡片默认这么长。
    public static let defaultCardDuration = 3.0
    /// 卡片最短这么久；再短就只看得到进出过渡、读不完字。
    public static let minimumCardDuration = 0.5
    /// 进出卡片时画面层缩小淡出所用的时间（两端各一次）。
    static let cardTransition = 0.35

    /// 成片某一时刻落在哪块卡片上。
    public func card(atTimeline time: Double) -> VideoClip? {
        guard clips.contains(where: { $0.card != nil }), let clip = clip(atTimeline: time), clip.card != nil else { return nil }
        return clip
    }

    /// 在成片的 `time` 处插入一块卡片，后面的一切往后挪出卡片的长度。返回卡片片段的 ID。
    ///
    /// 落在录制画面中间就先在那里切一刀（离边缘不足最小片段时长就贴到最近的边界）；
    /// 落在另一块卡片中间就接在它后面；落在空白或片尾就直接放下——片头、片尾卡片不需要有画面。
    /// 摄像头与两条声音轨同样在插入点切开再平移，卡片这段因此没有人像、没有声音。
    @discardableResult
    public mutating func insertCard(at time: Double, duration wanted: Double = Self.defaultCardDuration, content: TitleCard? = nil) -> UUID? {
        guard time.isFinite, wanted.isFinite else { return nil }
        let length = max(Self.minimumCardDuration, min(wanted, 600))
        let anchor = max(0, min(time, duration))
        materializeLayers()

        var pairs: [(head: UUID, tail: UUID)] = []
        var point = anchor
        let index = TimelineIndex(clips: orderedScreenClips)
        // 行归位用：卡片放进它旁边那块画面所在的行，而不是自己另起一行。
        let neighbor = index.clipIndex(at: min(anchor, max(0, duration - 0.00001))).map { index.clips[$0].id }
        if let number = index.clipIndex(at: anchor) {
            let clip = index.clips[number]
            let start = index.boundaries[number], end = start + clip.duration
            let offset = anchor - start
            if clip.card != nil { point = end }
            else if offset < Self.minimumClipDuration { point = start }
            else if clip.duration - offset < Self.minimumClipDuration { point = end }
            else if let tail = splitMedia(.screen, id: clip.id, at: anchor) { pairs.append((clip.id, tail)) }
            else { point = start }
        }
        // 四条轨都在插入点切开：只切画面的话，横跨插入点的声音会一路响进卡片里，
        // 而平移只挪"起点在插入点之后"的片段，碰不到它。
        pairs += splitTracks(at: point)
        rippleTimeline(from: point, by: length)

        var content = content ?? TitleCard()
        content.text.duration = length
        content.joins = pairs.isEmpty ? nil : pairs.map { TitleCard.Join(head: $0.head, tail: $0.tail) }
        var card = VideoClip(sourceStart: 0, duration: length)
        card.timelineStart = point
        card.card = content
        clips.append(card)

        // 层序放在旁边那块画面之上：卡片与画面并不重叠，但用户之后把画面拖过来时，卡片不该被盖住。
        var order = orderedLayerIDs
        order.removeAll { $0 == card.id }
        if let neighbor, let position = order.firstIndex(of: neighbor) { order.insert(card.id, at: position) }
        else { order.insert(card.id, at: 0) }
        layerOrder = order
        // 行归位：切开的两半回到同一行，卡片进它旁边那块画面所在的行；
        // 不这么做，插一块卡片会把画面轨和两条声音轨各拆出一行。
        for pair in pairs { placeBlock(pair.tail, inRowContaining: pair.head) }
        if let neighbor { placeBlock(card.id, inRowContaining: neighbor) }
        normalizeTimelineRows()
        normalizeSchemaVersion(layered: true)
        return card.id
    }

    /// 删掉一块卡片：后面的一切前移卡片的长度，插入时切开的片段若还连续就合回一块。
    /// 钉在卡片这段时间里的文字、遮罩、字幕（在卡片上加的标题之类）跟着卡片一起删掉：
    /// 以前它们留在原处，卡片一删、后面的画面前移，就盖到了不相干的画面上。
    public mutating func removeCard(id: UUID) {
        guard let clip = clips.first(where: { $0.id == id }), let content = clip.card else { return }
        let point = clip.timelineStart ?? 0, length = clip.duration
        let inside: (Double?) -> Bool = { start in start.map { $0 >= point - 0.0001 && $0 < point + length - 0.0001 } ?? false }
        for value in textList where inside(value.timelineStart) { removeText(id: value.id); layerOrder?.removeAll { $0 == value.id } }
        for value in maskList where inside(value.timelineStart) { removeMask(id: value.id); layerOrder?.removeAll { $0 == value.id } }
        captionList.removeAll { inside($0.timelineStart) }
        clips.removeAll { $0.id == id }
        rippleTimeline(from: point + length, by: -length)
        for join in content.joins ?? [] { rejoin(head: join.head, tail: join.tail, at: point) }
        normalizeTimelineRows()
    }

    /// 改卡片时长：后面的一切跟着挪，成片随之变长或变短。
    public mutating func setCardDuration(id: UUID, duration wanted: Double) {
        guard wanted.isFinite, let number = clips.firstIndex(where: { $0.id == id }), clips[number].card != nil else { return }
        let length = max(Self.minimumCardDuration, min(wanted, 600))
        let old = clips[number].duration, delta = length - old
        guard abs(delta) > 0.0001 else { return }
        let cardStart = clips[number].timelineStart ?? 0, end = cardStart + old
        clips[number].duration = length
        clips[number].card?.text.duration = length
        // 改短时，钉在被截掉那一截里的文字 / 遮罩 / 字幕挪回卡片之内（太长的文字、遮罩同时截到卡片长度），
        // 否则后面的画面前移后它们就盖在了别的画面上。
        if delta < 0 {
            let newEnd = cardStart + length
            let cut: (Double?) -> Bool = { start in start.map { $0 >= newEnd - 0.0001 && $0 < end - 0.0001 } ?? false }
            for value in textList where cut(value.timelineStart) {
                updateText(id: value.id) { text in
                    text.duration = min(text.duration, length)
                    text.timelineStart = max(cardStart, newEnd - text.duration)
                }
            }
            for value in maskList where cut(value.timelineStart) {
                updateMask(id: value.id) { mask in
                    mask.duration = min(mask.duration, length)
                    mask.timelineStart = max(cardStart, newEnd - mask.duration)
                    // 关键帧时间相对遮罩起点，必须落在时长之内：截短后超出的丢掉。
                    let limit = mask.duration + 0.001
                    mask.positionKeys = mask.positionKeys?.filter { $0.time <= limit }
                    mask.sizeKeys = mask.sizeKeys?.filter { $0.time <= limit }
                    mask.amountKeys = mask.amountKeys?.filter { $0.time <= limit }
                }
            }
            for cue in captionList where cut(cue.timelineStart) {
                updateCaption(id: cue.id) { $0.timelineStart = max(cardStart, newEnd - $0.sourceDuration) }
            }
        }
        rippleTimeline(from: end, by: delta)
        normalizeTimelineRows()
    }

    /// 改卡片内容（文字、背景）；时长与位置不动。
    public mutating func updateCard(id: UUID, _ change: (inout TitleCard) -> Void) {
        guard let number = clips.firstIndex(where: { $0.id == id }), var content = clips[number].card else { return }
        change(&content)
        content.text.start = 0; content.text.timelineStart = nil; content.text.layout = .fullscreen
        content.text.duration = clips[number].duration
        clips[number].card = content
    }

    /// 把插入卡片时切开的两半合回去：两半在同一条轨上首尾相接于 `point`、源时间连续、片段级参数一致才合。
    /// 用户在这期间改过其中一半（挪走、裁短、调了单块音量）就保持现状。
    private mutating func rejoin(head: UUID, tail: UUID, at point: Double) {
        for role in [TimelineMedia.screen, .camera, .system, .microphone] where ownsTrack(role) {
            var values = role == .screen ? clips : mediaClips(role)
            guard let h = values.firstIndex(where: { $0.id == head }), let t = values.firstIndex(where: { $0.id == tail }) else { continue }
            let first = values[h], second = values[t]
            let firstEnd = (first.timelineStart ?? 0) + first.duration
            guard abs(firstEnd - point) < 0.001, abs((second.timelineStart ?? 0) - point) < 0.001,
                  first.mediaDuration == nil || first.playableDuration >= first.duration - 0.0001,
                  abs(first.sourceStart + first.duration - second.sourceStart) < 0.001,
                  first.systemGain == second.systemGain, first.microphoneGain == second.microphoneGain,
                  first.cursorHidden == second.cursorHidden, first.card == nil, second.card == nil else { continue }
            values[h].duration = first.duration + second.duration
            values[h].mediaDuration = second.mediaDuration.map { first.duration + $0 }
            values.remove(at: t)
            if role == .screen {
                clips = values
                // 绑在尾块上的镜头改认头块，合并后镜头不会因为目标没了而掉线。
                for number in focuses.indices where focuses[number].targetClipID == tail { focuses[number].targetClipID = head }
            } else { setMediaClips(role, values) }
            layerOrder?.removeAll { $0 == tail }
            return
        }
    }

    /// 卡片这一刻的版式进度：卡片期间为 1，进卡片前与出卡片后各 `cardTransition` 秒从 0 渐到 1 / 从 1 渐到 0。
    /// 画面层按这个进度缩小淡出，与全屏文字同一条曲线，进出卡片看起来就是画面"退场"再"回来"。
    func cardStageProgress(at time: Double) -> Double {
        var best = 0.0
        for clip in clips where clip.card != nil {
            let start = clip.timelineStart ?? 0, end = start + clip.duration
            let edge = max(0.0001, min(Self.cardTransition, clip.duration / 2))
            let progress: Double
            if time >= start, time < end { progress = 1 }
            else if time >= start - edge, time < start { progress = SceneEvaluator.smootherstep((time - (start - edge)) / edge) }
            else if time >= end, time < end + edge { progress = SceneEvaluator.smootherstep(1 - (time - end) / edge) }
            else { continue }
            best = max(best, progress)
        }
        return best
    }

    /// 背景要换成卡片自己的颜色时：哪种颜色、盖上多少（与画面淡出同一进度）。跟随画布背景的卡片返回 nil。
    public func cardBackground(at time: Double) -> (color: TextSegment.Palette, amount: Double)? {
        guard time.isFinite else { return nil }
        var result: (color: TextSegment.Palette, amount: Double)?
        for clip in clips {
            guard let content = clip.card, let color = content.background else { continue }
            let start = clip.timelineStart ?? 0, end = start + clip.duration
            let edge = max(0.0001, min(Self.cardTransition, clip.duration / 2))
            let amount: Double
            if time >= start, time < end { amount = 1 }
            else if time >= start - edge, time < start { amount = SceneEvaluator.smootherstep((time - (start - edge)) / edge) }
            else if time >= end, time < end + edge { amount = SceneEvaluator.smootherstep(1 - (time - end) / edge) }
            else { continue }
            if amount > (result?.amount ?? 0) { result = (color, amount) }
        }
        return result
    }

    /// 卡片文字在成片上的样子：时间换成卡片片段的起止，渲染、画布编辑、面板读到的都是这一份。
    func cardText(_ clip: VideoClip) -> TextSegment? {
        guard var value = clip.card?.text else { return nil }
        value.start = 0
        value.timelineStart = clip.timelineStart ?? 0
        value.duration = clip.duration
        value.layout = .fullscreen
        return value
    }

    /// 这一刻要画的卡片文字（排在普通文字之下）。
    func cardTextStates(at time: Double) -> [TextState] {
        guard time.isFinite else { return [] }
        return clips.compactMap { clip -> TextState? in
            guard clip.card != nil, let value = cardText(clip), value.enabled, !value.text.isEmpty else { return nil }
            let start = clip.timelineStart ?? 0
            guard time >= start, time < start + clip.duration else { return nil }
            let animation = value.animation(elapsed: time - start)
            guard animation.alpha > 0.001 else { return nil }
            let count = value.text.count
            let revealed = animation.reveal >= 1 ? count : max(0, min(count, Int((Double(count) * animation.reveal).rounded())))
            return TextState(id: value.id, segment: value, animation: animation, revealedCount: revealed)
        }
    }

    /// 卡片片段里那段文字属于哪块卡片。
    public func cardID(forText id: UUID) -> UUID? {
        clips.first { $0.card?.text.id == id }?.id
    }

    /// 旧版"全屏卡段"（定格片段 + 绑着它的全屏文字 + 人像定格）在读取时换成卡片：
    /// 位置、时长、文字与样式都保留，成片总长不变；人像轨上的那一帧定格删掉（卡片期间人像本来就不显示）。
    /// 定格片段已经不在的，文字留下来当普通的全屏文字。
    public mutating func migrateLegacyHoldCards() {
        let legacy = textList.filter { $0.holdClipID != nil }
        guard !legacy.isEmpty else { return }
        for value in legacy {
            guard let clipID = value.holdClipID, let number = clips.firstIndex(where: { $0.id == clipID }) else {
                updateText(id: value.id) { $0.holdClipID = nil }
                continue
            }
            let frozen = clips[number]
            let start = frozen.timelineStart ?? 0
            if var values = cameraClips,
               let still = values.firstIndex(where: { $0.holdSource != nil && abs(($0.timelineStart ?? -1) - start) < 0.001 }) {
                let id = values[still].id
                values.remove(at: still); cameraClips = values
                layerOrder?.removeAll { $0 == id }
            }
            var text = value
            text.holdClipID = nil
            clips[number].card = TitleCard(text: text)
            clips[number].card?.text.duration = frozen.duration
            clips[number].sourceStart = 0
            clips[number].mediaDuration = nil
            clips[number].holdSource = nil
            if clips[number].title == "定格卡段" { clips[number].title = nil }
            removeText(id: value.id)
        }
        normalizeTimelineRows()
    }
}

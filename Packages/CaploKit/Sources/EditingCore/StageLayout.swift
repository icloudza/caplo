import Foundation
import CoreGraphics

/// 「画面层」在画布上的摆放：背景之上、文字与字幕之下的那一整层（卡片阴影、录屏、遮罩、光标、圆角、人像）
/// 作为一个整体被缩放、挪位、淡出。背景恒满幅，不参与这个变换——否则缩小时会露出黑边。
///
/// 全屏卡段用它把画面淡出、微微缩小；左右分屏用它把画面挤到半区。
/// 因为是相似变换，从常态到目标之间可以连续插值，版式过渡天然平滑。
public struct StageTransform: Equatable, Sendable {
    /// 相对画布的缩放；1 是常态。
    public var scale: Double = 1
    /// 画面层中心在画布上的归一化位置（左上原点）。
    public var centerX: Double = 0.5
    public var centerY: Double = 0.5
    public var alpha: Double = 1
    /// 这是"画面退到一栏、另一栏放文字"的分屏，不是整体淡出。
    /// 渲染时据此把浮在录屏之上的画中画从画面层里摘出来——人像跟着画面一起缩到半栏就没法看了。
    public var split = false

    public init(scale: Double = 1, centerX: Double = 0.5, centerY: Double = 0.5, alpha: Double = 1, split: Bool = false) {
        self.scale = scale; self.centerX = centerX; self.centerY = centerY; self.alpha = alpha; self.split = split
    }

    /// 画面层当前占着画布上的哪一块（Core Image 左下原点）。摘出来的画中画摆在这里面。
    public func region(canvas: CGSize) -> CGRect {
        CGRect(origin: .zero, size: canvas).applying(affine(canvas: canvas))
    }

    /// 常态：什么都不用做，渲染时可以整段跳过。
    public var isIdentity: Bool {
        abs(scale - 1) < 0.0005 && abs(centerX - 0.5) < 0.0005 && abs(centerY - 0.5) < 0.0005 && alpha > 0.9995
    }

    /// 画布像素坐标下的仿射变换（Core Image 左下原点）。
    public func affine(canvas: CGSize) -> CGAffineTransform {
        let target = CGPoint(x: centerX * canvas.width, y: (1 - centerY) * canvas.height)
        return CGAffineTransform(translationX: -canvas.width / 2, y: -canvas.height / 2)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: target.x, y: target.y))
    }

    /// 从常态按 `progress`（0…1）插值到目标。
    public static func blend(_ target: StageTransform, progress: Double) -> StageTransform {
        let t = min(1, max(0, progress))
        return StageTransform(scale: 1 + (target.scale - 1) * t,
                              centerX: 0.5 + (target.centerX - 0.5) * t,
                              centerY: 0.5 + (target.centerY - 0.5) * t,
                              alpha: 1 + (target.alpha - 1) * t,
                              split: target.split && t > 0.0001)
    }
}

extension TextSegment {
    /// 画面层外缘留白，占画布宽 / 高的比例。
    public static let stagePadding = 0.06
    /// 全屏时画面缩到这么大再淡出——不缩的话淡出看起来像画面"消失"，缩一点才像"退场"。
    public static let holdScale = 0.92
    /// 分屏时画面能占的比例区间。两端都给对面留下至少四分之一。
    public static let splitRatioRange: ClosedRange<Double> = 0.25...0.75

    /// 分屏时两栏各自占画布宽度的哪一段（归一化，左→右）。
    /// `stageTarget` 与 `textBoxFraction` 都从这里取，免得两处各算一遍、画面和文字对不上。
    var splitColumns: (picture: ClosedRange<Double>, text: ClosedRange<Double>) {
        let pad = Self.stagePadding
        let gap = min(0.3, max(0, splitGap.isFinite ? splitGap / 960 : 0.05))
        let usable = max(0.2, 1 - 2 * pad - gap)
        let ratio = Self.splitRatioRange.contains(splitRatio) ? splitRatio : 0.5
        let picture = usable * ratio, text = usable - picture
        // 文字在左，画面就去右栏；反之亦然。
        if layout == .splitLeft {
            return (picture: (1 - pad - picture)...(1 - pad), text: pad...(pad + text))
        }
        return (picture: pad...(pad + picture), text: (1 - pad - text)...(1 - pad))
    }

    /// 这段文字要求的画面层摆放（完全生效时）。叠加式不改变画面。
    public var stageTarget: StageTransform {
        switch layout {
        case .overlay: StageTransform()
        // 全屏：文字占满画面，底下的录制画面缩一点再淡出——不这样的话"全屏"和"叠加"看不出区别。
        // 开不开「插入时长」只决定成片会不会因此变长（画面冻结）还是照常往下播。
        case .fullscreen: StageTransform(scale: Self.holdScale, alpha: 0)
        case .splitLeft, .splitRight:
            {
                let column = splitColumns.picture
                let width = column.upperBound - column.lowerBound
                return StageTransform(scale: width, centerX: (column.lowerBound + column.upperBound) / 2, split: true)
            }()
        }
    }

    /// 文字盒在画布上的归一化矩形（左上原点）。分屏时它占画面对面的那一栏。
    public var textBoxFraction: CGRect {
        let pad = Self.stagePadding
        switch layout {
        case .overlay: return CGRect(x: pad, y: pad, width: 1 - 2 * pad, height: 1 - 2 * pad)
        case .fullscreen: return CGRect(x: 0.10, y: 0.14, width: 0.80, height: 0.72)
        case .splitLeft, .splitRight:
            let column = splitColumns.text
            return CGRect(x: column.lowerBound, y: 0.10, width: column.upperBound - column.lowerBound, height: 0.80)
        }
    }

    /// 版式生效的程度 0…1：两端各用 `layoutTransition` 秒渐入渐出，中间恒为 1。
    /// 与进出场动画分开：文字可以已经淡入完毕，而画面还在往半区退。
    public func layoutProgress(elapsed: Double) -> Double {
        guard layout != .overlay else { return 0 }
        let edge = max(0.0001, min(layoutTransition, duration / 2))
        let phase = min(elapsed / edge, (duration - elapsed) / edge)
        return SceneEvaluator.smootherstep(phase)
    }
}

extension VideoEdit {
    /// 这一刻画面层该怎么摆。多段文字同时要求版式时，取**退得最狠**的那一段（露出来的画面最少），
    /// 一样狠才让后加的压前面的。
    ///
    /// 单纯"后加的压前面的"会闪：两段全屏标题首尾交叠时，前一段已经全黑、后一段刚起步（版式还没生效），
    /// 后者一覆盖，画面就在一帧里弹回满亮度再重新淡出。
    public func stage(at time: Double, spans: [TextSpan]? = nil) -> StageTransform {
        guard !textList.isEmpty, time.isFinite else { return StageTransform() }
        let all = spans ?? textSpans()
        var winner: (coverage: Double, transform: StageTransform)?
        // 一个字都没有的文字不改变画面：新建一段全屏文字、还没来得及打字，
        // 画面不能就这么整段黑掉（activeTexts 同样不画空文字）。
        for value in textList where value.enabled && value.layout != .overlay && !value.text.isEmpty {
            guard let span = all.first(where: { $0.textID == value.id && time >= $0.start && time < $0.end }) else { continue }
            let elapsed = min(max(0, time - span.start), span.duration) + span.offset
            let progress = value.layoutProgress(elapsed: elapsed)
            guard progress > 0.0001 else { continue }
            let candidate = StageTransform.blend(value.stageTarget, progress: progress)
            // "露出来的画面"按面积算：不透明度乘以缩放的平方。小的那个赢。
            if let winner, winner.coverage < candidate.alpha * candidate.scale * candidate.scale - 0.0001 { continue }
            winner = (candidate.alpha * candidate.scale * candidate.scale, candidate)
        }
        return winner?.transform ?? StageTransform()
    }

    /// 这一刻是不是处在一段全屏卡段里（画面冻结、声音静音）。时间线上要画冻结带。
    public func holdCard(at time: Double, spans: [TextSpan]? = nil) -> TextSegment? {
        let all = spans ?? textSpans()
        return textList.first { value in
            value.holdClipID != nil && all.contains { $0.textID == value.id && time >= $0.start && time < $0.end }
        }
    }
    /// 工程里所有的全屏卡段，按成片时间排序。
    public var holdCards: [TextSegment] {
        textList.filter { $0.holdClipID != nil }.sorted { ($0.timelineStart ?? 0) < ($1.timelineStart ?? 0) }
    }
    /// 卡段一共插入了多少时长。面板上要告诉用户"成片被撑长了多少"。
    public var holdCardTotal: Double { holdCards.reduce(0) { $0 + $1.duration } }
}

// MARK: - 全屏卡段的插入与删除

extension VideoEdit {
    /// 卡段最短这么久；再短就只看得到过渡、看不到文字。
    public static let minimumHoldDuration = 0.4

    /// 在成片的某个时刻插入一段全屏卡段：画面冻结在这一刻、声音静音，文字浮在上面。
    ///
    /// 实现上它就是一条 `mediaDuration` 只有一帧的录制画面片段——合成器已有的"保持末帧"机制
    /// （插入 1 帧再 `scaleTimeRange` 拉长）会把那一帧持续输出。因此成片总长、播放头、
    /// 导出、时间线全都自动跟着变长，不需要另造一套时间轴。
    ///
    /// 返回新文字的 ID；播放头落在时间线空白处、或工程还没有画面时返回 nil。
    @discardableResult
    public mutating func insertHoldCard(at time: Double, duration wanted: Double, sourceDuration: Double,
                                        preset: TextPreset = .title, text: String = "",
                                        frameRate: Double = 30) -> UUID? {
        guard time.isFinite, sourceDuration.isFinite, sourceDuration > 0, !clips.isEmpty else { return nil }
        let length = max(Self.minimumHoldDuration, min(wanted, 600))
        let anchor = max(0, min(time, duration))
        guard let freeze = sourceTime(at: min(anchor, max(0, duration - 0.00001))) else { return nil }
        materializeLayers()

        // 插入点必须落在片段边界上：在片段中间就先切一刀，切不动（离边缘不足最小时长）就贴到最近的边界。
        // 每切一刀都记下"原块 → 尾块"，最后要把两半按回同一行：加一段卡段不该把一条轨拆成好几行。
        var pairs: [(head: UUID, tail: UUID)] = []
        var point = anchor
        let index = TimelineIndex(clips: orderedScreenClips)
        // 插入点这一刻在放哪条片段：定格片段要认它当"冻结自"，镜头才跟得过来。
        let anchorID = index.clipIndex(at: min(anchor, max(0, duration - 0.00001))).map { index.clips[$0].id }
        if let number = index.clipIndex(at: anchor) {
            let clip = index.clips[number]
            let start = index.boundaries[number], end = start + clip.duration
            let offset = anchor - start
            if offset < Self.minimumClipDuration { point = start }
            else if clip.duration - offset < Self.minimumClipDuration { point = end }
            else if let tail = splitMedia(.screen, id: clip.id, at: anchor) { pairs.append((clip.id, tail)) }
            else { point = start }
        }

        // 人像也要有一帧冻在那里：只给画面轨加定格的话，卡段这一段摄像头轨是空的，
        // 画中画会在卡段开始时整个消失、结束时再弹回来，而不是跟着画面一起淡出。
        var cameraAnchorID: UUID?
        let cameraFreeze: Double? = {
            let values = mediaClips(.camera)
            guard !values.isEmpty else { return nil }
            let cameraIndex = TimelineIndex(clips: values)
            guard let number = cameraIndex.clipIndex(at: min(anchor, max(0, duration - 0.00001))) else { return nil }
            let clip = cameraIndex.clips[number]
            cameraAnchorID = clip.id
            return clip.sourceStart + max(0, min(clip.playableDuration - 0.00001, anchor - cameraIndex.boundaries[number]))
        }()

        // 四条轨都要在插入点切开：只切画面的话，横跨插入点的声音片段会一路响进卡段里，
        // 而 ripple 只平移"起点在插入点之后"的片段，碰不到它。
        pairs += splitTracks(at: point)
        rippleTimeline(from: point, by: length)

        // 那一帧也要整个落在素材里：贴着片尾冻结时 sourceStart + 一帧会越过素材末尾，校验会拒收。
        let frame = min(length, max(0.00001, 1 / max(24, frameRate)))
        let frozenStart = max(0, min(freeze, sourceDuration - frame))
        var frozen = VideoClip(sourceStart: frozenStart, duration: length)
        frozen.timelineStart = point
        frozen.holdSource = anchorID
        // 只留一帧可用素材，其余由"保持末帧"补齐——这一帧就是被冻住的画面。
        frozen.mediaDuration = frame
        frozen.title = "定格卡段"
        clips.append(frozen)

        if let cameraFreeze {
            var still = VideoClip(sourceStart: max(0, min(cameraFreeze, sourceDuration - frame)), duration: length)
            still.timelineStart = point
            still.mediaDuration = frame
            still.holdSource = cameraAnchorID
            still.title = "定格卡段"
            cameraClips = (cameraClips ?? []) + [still]
        }

        var card = preset.segment(start: frozenStart, duration: length)
        card.text = text.isEmpty ? preset.sample : text
        card.layout = .fullscreen
        card.timelineStart = point
        card.holdClipID = frozen.id
        addText(card)

        var order = orderedLayerIDs
        order.removeAll { $0 == frozen.id || $0 == card.id }
        order.insert(card.id, at: 0)
        // 定格片段排在录制画面那一侧，紧挨着插入点前面那一块。
        if let anchorID, let position = order.firstIndex(of: anchorID) {
            order.insert(frozen.id, at: position + 1)
        } else { order.append(frozen.id) }
        layerOrder = order

        // 行归位：切开的两半回到同一行，定格片段插在它冻结自的那一块旁边。
        // 不这么做的话，加一段卡段会把画面轨拆成"录制画面 01 / 定格卡段 / 录制画面 02"三行，
        // 声音轨也各裂一行——时间线一下子多出四五行，用户看到的就是"乱七八糟"。
        for pair in pairs { placeBlock(pair.tail, inRowContaining: pair.head) }
        if let anchorID { placeBlock(frozen.id, inRowContaining: anchorID) }
        if let cameraAnchorID, let still = cameraClips?.last, still.holdSource == cameraAnchorID {
            placeBlock(still.id, inRowContaining: cameraAnchorID)
        }
        normalizeTimelineRows()
        normalizeSchemaVersion(layered: true)
        return card.id
    }

    /// 删掉一段卡段：定格片段一起删，后面的一切前移同样的时长。
    public mutating func removeHoldCard(textID: UUID) {
        guard let card = text(id: textID), let clipID = card.holdClipID,
              let frozen = clips.first(where: { $0.id == clipID }) else { return }
        let point = frozen.timelineStart ?? 0, length = frozen.duration
        clips.removeAll { $0.id == clipID }
        removeText(id: textID)
        rippleTimeline(from: point + length, by: -length)
        normalizeTimelineRows()
    }

    /// 改卡段时长：定格片段与文字一起变，后面的一切跟着挪。
    public mutating func setHoldCardDuration(textID: UUID, duration wanted: Double) {
        guard let card = text(id: textID), let clipID = card.holdClipID,
              let number = clips.firstIndex(where: { $0.id == clipID }) else { return }
        let length = max(Self.minimumHoldDuration, min(wanted, 600))
        let old = clips[number].duration
        let delta = length - old
        guard abs(delta) > 0.0001 else { return }
        let end = (clips[number].timelineStart ?? 0) + old
        clips[number].duration = length
        clips[number].mediaDuration = min(length, clips[number].mediaDuration ?? length)
        updateText(id: textID) { $0.duration = length }
        rippleTimeline(from: end, by: delta)
        normalizeTimelineRows()
    }

    /// 在插入点把各条轨切开，好让接下来的平移不会漏掉横跨插入点的片段。
    /// 返回每条轨切出来的"原块 → 尾块"，调用方要把两半按回同一行。
    @discardableResult
    mutating func splitTracks(at point: Double) -> [(head: UUID, tail: UUID)] {
        var pairs: [(head: UUID, tail: UUID)] = []
        for role in [TimelineMedia.camera, .system, .microphone, .screen] {
            let values = role == .screen ? clips : mediaClips(role)
            guard !values.isEmpty else { continue }
            let index = TimelineIndex(clips: values)
            guard let number = index.clipIndex(at: point) else { continue }
            let clip = index.clips[number]
            let start = index.boundaries[number]
            guard point > start + 0.0001, point < start + clip.duration - 0.0001 else { continue }
            if let tail = splitMedia(role, id: clip.id, at: point) { pairs.append((clip.id, tail)); continue }
            // 切不动：插入点离这一块的某一头不足最小片段时长。
            // 这时把那不到 0.25 秒的一小截**裁掉**，而不是把整块平移——
            // 平移会让这条轨相对画面错开同样的时间，一段对不上口型的声音比少半句话难受得多。
            var updated = role == .screen ? clips : mediaClips(role)
            guard let position = updated.firstIndex(where: { $0.id == clip.id }) else { continue }
            let head = point - start, tail = clip.duration - head
            let keep = min(head, tail) == head ? tail : head
            guard keep >= 1.0 / 60 else { updated.remove(at: position); setMediaClips(role, updated); continue }
            if head < tail {
                // 插入点贴着开头：裁掉开头那一小截，让这块从插入点开始，源时间同步前移。
                updated[position].timelineStart = point
                updated[position].sourceStart += min(head, max(0, updated[position].playableDuration - 0.00001))
                updated[position].duration = tail
                if let media = updated[position].mediaDuration { updated[position].mediaDuration = max(0.00001, media - head) }
            } else {
                // 插入点贴着结尾：裁掉结尾那一小截，让这块在插入点结束。
                updated[position].duration = head
                if let media = updated[position].mediaDuration { updated[position].mediaDuration = min(media, head) }
            }
            setMediaClips(role, updated)
        }
        return pairs
    }

    /// 把插入点之后的一切整体挪 `delta` 秒。
    ///
    /// 要挪的只有"存成片时间"的东西：四条轨的片段起点、已固定的聚焦、已固定的文字与字幕。
    /// 遮罩 / 文字 / 字幕存的是源时间、靠剪辑表投影，所以它们**不需要**动——
    /// 后面的片段一挪，它们的投影自然跟着走。
    mutating func rippleTimeline(from point: Double, by delta: Double) {
        guard delta.isFinite, abs(delta) > 0.0001 else { return }
        let threshold = point - 0.0001
        for role in [TimelineMedia.screen, .camera, .system, .microphone] {
            var values = role == .screen ? clips : mediaClips(role)
            guard !values.isEmpty else { continue }
            var changed = false
            for number in values.indices {
                guard let start = values[number].timelineStart, start >= threshold else { continue }
                values[number].timelineStart = max(0, start + delta); changed = true
            }
            guard changed else { continue }
            switch role {
            case .screen: clips = values
            case .camera: cameraClips = values
            case .system: systemClips = values
            case .microphone: microphoneClips = values
            }
        }
        for number in focuses.indices {
            guard let start = focuses[number].timelineStart else { continue }
            if start >= threshold { focuses[number].timelineStart = max(0, start + delta) }
            // 跨过插入点的镜头拉长同样的时长，插入点两侧的画面内容仍然被它盖住。
            // 衔接进来的镜头带着 transitionOffset / transitionDuration（整条运镜包络的长度），
            // 只加 duration 会让 offset + duration 越过包络长度：validate 直接判无效，
            // 于是插完卡段保存、播放、导出全都报"内容无效"。包络要跟着一起变长。
            else if start + focuses[number].duration > threshold {
                focuses[number].duration = max(1.0 / 30, focuses[number].duration + delta)
                if let length = focuses[number].transitionDuration {
                    focuses[number].transitionDuration = max(1.0 / 30, length + delta)
                }
            }
        }
        for value in textList where value.timelineStart != nil {
            guard let start = value.timelineStart, start >= threshold else { continue }
            updateText(id: value.id) { $0.timelineStart = max(0, start + delta) }
        }
        for cue in captionList where cue.timelineStart != nil {
            guard let start = cue.timelineStart, start >= threshold else { continue }
            updateCaption(id: cue.id) { $0.timelineStart = max(0, start + delta) }
        }
        for value in maskList where value.timelineStart != nil {
            guard let start = value.timelineStart, start >= threshold else { continue }
            updateMask(id: value.id) { $0.timelineStart = max(0, start + delta) }
        }
    }

    /// 这一刻是不是停在某段定格卡段上。停在卡段上新建的叠加层要钉在成片时间上：
    /// 定格片段的源区间与它后面那条正片片段是同一段，按源域建的话会在卡段和正片上各画一次。
    public func holdClip(atTimeline time: Double) -> VideoClip? {
        guard !textList.isEmpty, let clip = clip(atTimeline: time) else { return nil }
        return holdCards.contains { $0.holdClipID == clip.id } ? clip : nil
    }

    /// 让卡段文字与它的定格片段保持同步。任何一条改动片段的路径（拖边、删除、撤销）之后都要跑一遍：
    /// 片段还在就把文字的起止对齐过去，片段没了就把文字留下来变成普通的全屏文字，不让它悬空。
    public mutating func syncHoldCards() {
        guard !textList.isEmpty else { return }
        var list = textList
        var changed = false
        for index in list.indices {
            guard let clipID = list[index].holdClipID else { continue }
            guard let clip = clips.first(where: { $0.id == clipID }) else {
                list[index].holdClipID = nil; changed = true; continue
            }
            let start = clip.timelineStart ?? 0
            let length = max(0.05, clip.duration)
            // 卡段只能是全屏版式：定格片段是按"整幅画面被文字盖住"插进去的。
            // 哪条路径把它改成了分屏，就在这里掰回来——否则整份工程会被校验判无效、编辑整笔回滚。
            if list[index].layout != .fullscreen { list[index].layout = .fullscreen; changed = true }
            guard list[index].timelineStart != start || abs(list[index].duration - length) > 0.0001 else { continue }
            list[index].timelineStart = start
            list[index].duration = length
            changed = true
        }
        if changed { textList = list }
    }

    /// 把一段已有的全屏文字转成卡段（插入真实时长），或反过来撤掉。
    /// 返回是否真的改动了。
    @discardableResult
    public mutating func setHoldCard(textID: UUID, enabled: Bool, sourceDuration: Double, frameRate: Double = 30) -> Bool {
        guard let value = text(id: textID) else { return false }
        if enabled {
            guard value.holdClipID == nil else { return false }
            // 先记下它现在在成片上的位置与时长，删掉之后原地插一段卡段。
            let spans = textSpans().filter { $0.textID == textID }
            let start = value.timelineStart ?? spans.first?.start ?? 0
            let length = max(Self.minimumHoldDuration, value.duration)
            var preserved = value
            removeText(id: textID)
            guard let created = insertHoldCard(at: start, duration: length, sourceDuration: sourceDuration,
                                               preset: .title, text: preserved.text, frameRate: frameRate) else {
                addText(preserved)   // 插不进去（比如播放头在空白处）就原样放回，不能把用户的文字弄丢。
                return false
            }
            preserved.id = created
            preserved.layout = .fullscreen
            preserved.timelineStart = text(id: created)?.timelineStart
            preserved.duration = text(id: created)?.duration ?? length
            preserved.holdClipID = text(id: created)?.holdClipID
            updateText(id: created) { $0 = preserved }
            return true
        }
        guard let clipID = value.holdClipID, let frozen = clips.first(where: { $0.id == clipID }) else { return false }
        // 撤掉插入的时长，但把文字留下来（变成盖在画面上的全屏文字）。
        var kept = value
        kept.holdClipID = nil
        let point = frozen.timelineStart ?? 0, length = frozen.duration
        clips.removeAll { $0.id == clipID }
        updateText(id: textID) { $0 = kept }
        rippleTimeline(from: point + length, by: -length)
        normalizeTimelineRows()
        return true
    }
}

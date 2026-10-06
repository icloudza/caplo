import Foundation
import CoreGraphics

/// 「画面层」在画布上的摆放：背景之上、文字与字幕之下的那一整层（卡片阴影、录屏、遮罩、光标、圆角、人像）
/// 作为一个整体被缩放、挪位、淡出。背景恒满幅，不参与这个变换——否则缩小时会露出黑边。
///
/// 全屏文字与卡片用它把画面淡出、微微缩小；左右分屏用它把画面挤到半区。
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
    /// 画面布局「留白」在这一刻还剩多少（1 常态、0 完全收起）。分屏时画面要铺满自己那一栏：
    /// 留白本来是给画面四周留空的，再连同画面一起缩进栏里就成了两层空白，白白浪费一栏的宽度。
    public var paddingScale: Double = 1

    public init(scale: Double = 1, centerX: Double = 0.5, centerY: Double = 0.5, alpha: Double = 1, split: Bool = false, paddingScale: Double = 1) {
        self.scale = scale; self.centerX = centerX; self.centerY = centerY; self.alpha = alpha; self.split = split; self.paddingScale = paddingScale
    }

    /// 画面层当前占着画布上的哪一块（Core Image 左下原点）。摘出来的画中画摆在这里面。
    public func region(canvas: CGSize) -> CGRect {
        CGRect(origin: .zero, size: canvas).applying(affine(canvas: canvas))
    }

    /// 常态：什么都不用做，渲染时可以整段跳过。
    public var isIdentity: Bool {
        abs(scale - 1) < 0.0005 && abs(centerX - 0.5) < 0.0005 && abs(centerY - 0.5) < 0.0005 && alpha > 0.9995 && abs(paddingScale - 1) < 0.0005
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
                              split: target.split && t > 0.0001,
                              paddingScale: 1 + (target.paddingScale - 1) * t)
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
        let ratio = Self.splitRatioRange.contains(splitRatio) ? splitRatio : Self.defaultSplitRatio
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
                // 留白随版式过渡一起收到 0：画面铺满这一栏，只留分屏栏自己的外缘。
                return StageTransform(scale: width, centerX: (column.lowerBound + column.upperBound) / 2, split: true, paddingScale: 0)
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
        guard time.isFinite else { return StageTransform() }
        let hasCards = clips.contains { $0.card != nil }
        guard !textList.isEmpty || hasCards else { return StageTransform() }
        var winner: (coverage: Double, transform: StageTransform)?
        func offer(_ candidate: StageTransform) {
            // "露出来的画面"按面积算：不透明度乘以缩放的平方。小的那个赢。
            if let winner, winner.coverage < candidate.alpha * candidate.scale * candidate.scale - 0.0001 { return }
            winner = (candidate.alpha * candidate.scale * candidate.scale, candidate)
        }
        if !textList.isEmpty {
            let all = spans ?? textSpans()
            // 一个字都没有的文字不改变画面：新建一段全屏文字、还没来得及打字，
            // 画面不能就这么整段黑掉（activeTexts 同样不画空文字）。
            for value in textList where value.enabled && value.layout != .overlay && !value.text.isEmpty {
                guard let span = all.first(where: { $0.textID == value.id && time >= $0.start && time < $0.end }) else { continue }
                let elapsed = min(max(0, time - span.start), span.duration) + span.offset
                let progress = value.layoutProgress(elapsed: elapsed)
                guard progress > 0.0001 else { continue }
                offer(StageTransform.blend(value.stageTarget, progress: progress))
            }
        }
        // 卡片：进卡片前画面层缩小淡出、出卡片后再回来，与全屏文字同一个目标与曲线。
        if hasCards {
            let progress = cardStageProgress(at: time)
            if progress > 0.0001 { offer(StageTransform.blend(StageTransform(scale: TextSegment.holdScale, alpha: 0), progress: progress)) }
        }
        return winner?.transform ?? StageTransform()
    }
}

// MARK: - 插入时长用的两件工具（卡片插入、删除、改时长共用）

extension VideoEdit {
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
            // 卡片切不得，也不该被下面那条"裁掉一小截"的兜底削短。
            guard clip.card == nil, point > start + 0.0001, point < start + clip.duration - 0.0001 else { continue }
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
            // 于是插完卡片保存、播放、导出全都报"内容无效"。包络要跟着一起变长。
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
}

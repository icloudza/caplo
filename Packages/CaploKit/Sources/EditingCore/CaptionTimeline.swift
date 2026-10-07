import Foundation
import CoreGraphics

/// 一个词（中文里通常是一小段字）的源时间戳。
public struct CaptionWord: Codable, Equatable, Sendable {
    /// 源素材时间，与 `CaptionCue` 同一条时间轴。
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

/// 一句字幕。**唯一真相是源素材时间**：剪辑、删除、重排、复用素材全部由投影吸收，
/// 句子本身从不因为剪辑而改写。这和遮罩、文字层是同一套约定。
public struct CaptionCue: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var sourceStart: Double
    public var sourceEnd: Double
    public var text: String
    /// 逐词时间戳。中文常常整句只给一两段，这时按字均分兜底（见 `words(in:evenSplit:)`）。
    public var words: [CaptionWord]?
    /// 用户改过这一句：重新转写时保护它，不被新结果覆盖。
    public var locked = false
    /// 非空表示固定到成片时间，不再跟随剪辑。
    public var timelineStart: Double?
    /// 只对这一句生效的提前量与停留时长（仍然跟随剪辑）。
    public var lead: Double?
    public var tail: Double?
    public var enabled = true

    public init(sourceStart: Double, sourceEnd: Double, text: String, words: [CaptionWord]? = nil) {
        self.sourceStart = sourceStart; self.sourceEnd = sourceEnd; self.text = text; self.words = words
    }

    // 手写解码，理由同 TextSegment：合成的解码器不认默认值，缺一个键整份工程作废。
    private enum CodingKeys: String, CodingKey {
        case id, sourceStart, sourceEnd, text, words, locked, timelineStart, lead, tail, enabled
    }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        sourceStart = try box.decode(Double.self, forKey: .sourceStart)
        sourceEnd = try box.decode(Double.self, forKey: .sourceEnd)
        text = try box.decodeIfPresent(String.self, forKey: .text) ?? ""
        id = try box.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        words = try box.decodeIfPresent([CaptionWord].self, forKey: .words)
        locked = try box.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        timelineStart = try box.decodeIfPresent(Double.self, forKey: .timelineStart)
        lead = try box.decodeIfPresent(Double.self, forKey: .lead)
        tail = try box.decodeIfPresent(Double.self, forKey: .tail)
        enabled = try box.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public var sourceDuration: Double { max(0, sourceEnd - sourceStart) }
    /// 一句最多这么多字符。
    public static let textLimit = 400

    var isValid: Bool {
        guard sourceStart.isFinite, sourceStart >= 0, sourceEnd.isFinite, sourceEnd > sourceStart,
              text.count <= Self.textLimit,
              (timelineStart.map { $0.isFinite && $0 >= 0 } ?? true),
              (lead.map { $0.isFinite && (0...3).contains($0) } ?? true),
              (tail.map { $0.isFinite && (0...5).contains($0) } ?? true) else { return false }
        guard let words else { return true }
        guard words.count <= 4000 else { return false }
        var previous = -Double.infinity
        for word in words {
            guard word.start.isFinite, word.end.isFinite, word.end >= word.start, word.start >= previous - 0.001,
                  word.text.count <= 120 else { return false }
            previous = word.start
        }
        return true
    }
}

/// 全局字幕样式。逐句只覆盖文本与时间，样式统一，这样改一次全片一致。
public struct CaptionStyle: Codable, Equatable, Sendable {
    /// 逐词高亮的做法。
    public enum Highlight: String, Codable, CaseIterable, Sendable {
        case none, color, pill
        public var title: String { switch self { case .none: String(localized: "不高亮"); case .color: String(localized: "逐词变色"); case .pill: String(localized: "逐词药丸") } }
    }
    public enum Animation: String, Codable, CaseIterable, Sendable { case none, fade, rise, bounce }

    // 排版（尺寸按 1080 参考高度）
    public var family: TextSegment.Family = .system
    public var size: Double = 46
    public var weight: Double = 600
    public var lineHeight: Double = 1.25
    public var alignment: TextSegment.Alignment = .center
    public var maxWidth: Double = 0.72
    public var x: Double = 0.5
    public var y: Double = 0.86

    // 外观
    public var color: TextSegment.Palette = .white
    public var highlightColor: TextSegment.Palette = .amber
    public var highlight: Highlight = .none
    /// 词与词之间高亮切换的过渡时长。
    public var wordFade: Double = 0.09
    /// 没有可用词边界时按字数均分。中文的词级时间戳常常不可用，这个默认开。
    public var evenSplit = true
    public var plate = true
    public var plateColor: TextSegment.Palette = .ink
    public var plateOpacity: Double = 0.55
    public var platePadding: Double = 18
    public var plateRadius: Double = 8
    public var shadow = false
    public var shadowOpacity: Double = 0.45
    public var shadowBlur: Double = 14
    public var shadowOffset: Double = 4

    // 时序
    /// 提前出现。
    public var lead: Double = 0.06
    /// 说完之后停留。
    public var tail: Double = 0.35
    /// 最短显示时长，避免短句一闪而过。
    public var minHold: Double = 1.0
    /// 与下一句的间隔小于这个值时直接接上，不闪断。
    public var bridge: Double = 0.25
    public var fadeIn: Double = 0.12
    public var fadeOut: Double = 0.12
    public var animation: Animation = .fade
    /// 关掉之后导出的视频不带字幕（只留 SRT）。
    public var burnIn = true

    public init() {}

    // 手写解码，理由同上：字幕样式往后还会加参数，缺一个键不能让整份工程打不开。
    private enum CodingKeys: String, CodingKey {
        case family, size, weight, lineHeight, alignment, maxWidth, x, y
        case color, highlightColor, highlight, wordFade, evenSplit
        case plate, plateColor, plateOpacity, platePadding, plateRadius
        case shadow, shadowOpacity, shadowBlur, shadowOffset
        case lead, tail, minHold, bridge, fadeIn, fadeOut, animation, burnIn
    }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try box.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        family = try value(.family, TextSegment.Family.system)
        size = try value(.size, 46)
        weight = try value(.weight, 600)
        lineHeight = try value(.lineHeight, 1.25)
        alignment = try value(.alignment, TextSegment.Alignment.center)
        maxWidth = try value(.maxWidth, 0.72)
        x = try value(.x, 0.5)
        y = try value(.y, 0.86)
        color = try value(.color, TextSegment.Palette.white)
        highlightColor = try value(.highlightColor, TextSegment.Palette.amber)
        highlight = try value(.highlight, Highlight.none)
        wordFade = try value(.wordFade, 0.09)
        evenSplit = try value(.evenSplit, true)
        plate = try value(.plate, true)
        plateColor = try value(.plateColor, TextSegment.Palette.ink)
        plateOpacity = try value(.plateOpacity, 0.55)
        platePadding = try value(.platePadding, 18)
        plateRadius = try value(.plateRadius, 8)
        shadow = try value(.shadow, false)
        shadowOpacity = try value(.shadowOpacity, 0.45)
        shadowBlur = try value(.shadowBlur, 14)
        shadowOffset = try value(.shadowOffset, 4)
        lead = try value(.lead, 0.06)
        tail = try value(.tail, 0.35)
        minHold = try value(.minHold, 1.0)
        bridge = try value(.bridge, 0.25)
        fadeIn = try value(.fadeIn, 0.12)
        fadeOut = try value(.fadeOut, 0.12)
        animation = try value(.animation, Animation.fade)
        burnIn = try value(.burnIn, true)
    }

    public var isValid: Bool {
        [size, weight, lineHeight, maxWidth, x, y, wordFade, plateOpacity, platePadding, plateRadius,
         shadowOpacity, shadowBlur, shadowOffset, lead, tail, minHold, bridge, fadeIn, fadeOut].allSatisfy(\.isFinite)
            && TextSegment.sizeRange.contains(size) && TextSegment.weightRange.contains(weight)
            && (0.6...2.5).contains(lineHeight) && (0.1...1).contains(maxWidth)
            && (0...1).contains(x) && (0...1).contains(y)
            && (0...1).contains(wordFade) && (0...1).contains(plateOpacity) && (0...200).contains(platePadding)
            && (0...120).contains(plateRadius) && (0...1).contains(shadowOpacity) && (0...120).contains(shadowBlur)
            && (-80...80).contains(shadowOffset)
            && (0...3).contains(lead) && (0...5).contains(tail) && (0...10).contains(minHold) && (0...3).contains(bridge)
            && (0...3).contains(fadeIn) && (0...3).contains(fadeOut)
    }
}

extension CaptionStyle {
    /// 把字幕样式表达成一段"文字层"，好让渲染器走同一条排版路径。
    /// 字幕与文字层的排版参数本来就是同一组，没必要写两套 Core Text 代码。
    public func segment(text: String) -> TextSegment {
        var value = TextSegment(start: 0, duration: 1, text: text)
        value.family = family; value.size = size; value.weight = weight; value.lineHeight = lineHeight
        value.alignment = alignment; value.maxWidth = maxWidth; value.x = x; value.y = y
        value.color = color; value.plate = plate; value.plateColor = plateColor; value.plateOpacity = plateOpacity
        value.platePadding = platePadding; value.plateRadius = plateRadius
        value.shadow = shadow; value.shadowOpacity = shadowOpacity; value.shadowBlur = shadowBlur; value.shadowOffset = shadowOffset
        value.layout = .overlay
        return value
    }
}

extension CaptionState {
    /// 交给渲染器的形态：文本、动画状态与全文长度。
    public func renderState(style: CaptionStyle) -> TextState {
        let display = (headClipped ? "…" : "") + text + (tailClipped ? "…" : "")
        var segment = style.segment(text: display)
        segment.enterKind = .none; segment.exitKind = .none
        return TextState(id: cueID, segment: segment,
                         animation: TextAnimationState(alpha: alpha, offset: offset, scale: scale, reveal: 1),
                         revealedCount: display.count)
    }
    /// 当前高亮词在**显示文本**里的字符范围（开头补了省略号时整体后移一位）。
    public func highlightRange() -> (location: Int, length: Int)? {
        guard activeWord >= 0, activeWord < words.count, words[activeWord].length > 0 else { return nil }
        let shift = headClipped ? 1 : 0
        return (words[activeWord].location + shift, words[activeWord].length)
    }
}

/// 一句字幕在成片时间轴上的一段。被剪辑切开时一句会有多段。
public struct CaptionSpan: Sendable, Hashable {
    public let cueID: UUID
    public let clipID: UUID?
    public let start: Double
    public let duration: Double
    /// 这一段对应的源时间区间；逐词高亮按它裁剪。
    public let sourceLower: Double
    public let sourceUpper: Double
    /// 这一段的开头 / 结尾是被剪掉的（用于给断口加省略号）。
    public let headClipped: Bool
    public let tailClipped: Bool
    public var end: Double { start + duration }
}

/// 一句字幕这一刻的显示状态。渲染、画布与导出共用。
public struct CaptionState: Equatable, Sendable {
    public var cueID: UUID
    public var text: String
    /// 已投影到成片时间的词；空表示不做逐词高亮。
    public var words: [CaptionRenderWord]
    /// 当前正在念的词下标，-1 表示还没开口。
    public var activeWord: Int
    /// 当前词的高亮权重 0…1（词间过渡）。
    public var wordProgress: Double
    public var alpha: Double
    /// 入场位移，占画面高度的比例；正值向下。
    public var offset: Double
    public var scale: Double
    public var headClipped: Bool
    public var tailClipped: Bool
}

public struct CaptionRenderWord: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    /// 这个词在整句文本里的字符范围，渲染时按它上色。
    public var location: Int
    public var length: Int
}

extension VideoEdit {
    /// 字幕列表的非可选视图；写入后重算版本号。
    public var captionList: [CaptionCue] {
        get { captions ?? [] }
        set { captions = newValue.isEmpty ? nil : newValue; normalizeSchemaVersion() }
    }
    public var captionStyleOrDefault: CaptionStyle { captionStyle ?? CaptionStyle() }
    public mutating func updateCaption(id: UUID, _ change: (inout CaptionCue) -> Void) {
        var list = captionList
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index]); captionList = list
    }
    public func caption(id: UUID) -> CaptionCue? { captionList.first { $0.id == id } }

    /// 字幕在成片时间轴上的可见段。
    ///
    /// 与遮罩、文字层的一处关键差别：源侧上界用 `playableDuration` 而不是 `duration`。
    /// "保持末帧"的那段画面是静止的，那里没有人在说话，把字幕拖过去只会对不上口型。
    public func captionSpans(in range: Range<Double>? = nil, using existingIndex: TimelineIndex? = nil) -> [CaptionSpan] {
        let index = existingIndex ?? TimelineIndex(clips: orderedScreenClips)
        let visible = range ?? 0..<duration
        var result: [CaptionSpan] = []
        for cue in captionList where cue.enabled {
            if let start = cue.timelineStart {
                let length = cue.sourceDuration
                if start < visible.upperBound && start + length > visible.lowerBound {
                    result.append(CaptionSpan(cueID: cue.id, clipID: nil, start: start, duration: length,
                                              sourceLower: cue.sourceStart, sourceUpper: cue.sourceEnd,
                                              headClipped: false, tailClipped: false))
                }
                continue
            }
            // 按真正可见的段投影；上界用 playableDuration，"保持末帧"那段静止画面上没人说话。
            for span in index.visibleSpans(in: visible) {
                let clip = index.clips[span.index]
                // 卡片不引用素材，上面没有人说话。
                guard clip.card == nil else { continue }
                let base = index.boundaries[span.index]
                let shownLower = clip.sourceStart + (span.start - base)
                let shownUpper = clip.sourceStart + min(span.end - base, clip.playableDuration)
                let lower = max(shownLower, cue.sourceStart), upper = min(shownUpper, cue.sourceEnd)
                guard upper > lower + 0.000_001 else { continue }
                let start = span.start + (lower - shownLower)
                guard start < visible.upperBound, start + upper - lower > visible.lowerBound else { continue }
                result.append(CaptionSpan(cueID: cue.id, clipID: clip.id, start: start, duration: upper - lower,
                                          sourceLower: lower, sourceUpper: upper,
                                          headClipped: lower > cue.sourceStart + 0.000_001,
                                          tailClipped: upper < cue.sourceEnd - 0.000_001))
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// 一段字幕实际显示的时间范围：提前出现、说完停留、最短时长、与下一段不重叠也不闪断。
    /// 已固定到成片时间的句子所见即所得，不做任何修剪。
    public func captionDisplayRange(_ span: CaptionSpan, style: CaptionStyle, nextStart: Double?) -> ClosedRange<Double> {
        let cue = caption(id: span.cueID)
        if cue?.timelineStart != nil { return span.start...(span.start + span.duration) }
        let lead = max(0, cue?.lead ?? style.lead), tail = max(0, cue?.tail ?? style.tail)
        var lower = span.start - lead
        var upper = span.start + span.duration + tail
        if upper - lower < style.minHold { upper = lower + style.minHold }
        if let nextStart {
            let nextLower = nextStart - lead
            // 绝不与下一句重叠；间隔太小时直接接上，免得闪一下。
            if upper > nextLower - 0.001 || nextLower - upper < style.bridge { upper = nextLower - 0.001 }
        }
        lower = max(0, lower)
        return lower...max(lower + 0.001, upper)
    }

    /// 这一刻要画的字幕。同一时刻最多一句（后面的压前面的），字幕不叠着放。
    public func activeCaption(at time: Double, spans: [CaptionSpan]? = nil) -> CaptionState? {
        guard !captionList.isEmpty, time.isFinite else { return nil }
        let style = captionStyleOrDefault
        let all = spans ?? captionSpans()
        guard !all.isEmpty else { return nil }
        var chosen: (span: CaptionSpan, range: ClosedRange<Double>)?
        for (number, span) in all.enumerated() {
            let range = captionDisplayRange(span, style: style, nextStart: number + 1 < all.count ? all[number + 1].start : nil)
            guard range.contains(time) else { continue }
            chosen = (span, range)
        }
        guard let chosen, let cue = caption(id: chosen.span.cueID), !cue.text.isEmpty else { return nil }
        let length = chosen.range.upperBound - chosen.range.lowerBound
        let fadeIn = max(0.001, min(style.fadeIn, length / 2)), fadeOut = max(0.001, min(style.fadeOut, length / 2))
        let alpha = min(SceneEvaluator.smootherstep((time - chosen.range.lowerBound) / fadeIn),
                        SceneEvaluator.smootherstep((chosen.range.upperBound - time) / fadeOut))
        guard alpha > 0.002 else { return nil }
        let entrance = Self.captionEntrance(style: style, elapsed: time - chosen.range.lowerBound)
        let words = Self.renderWords(cue: cue, span: chosen.span, style: style)
        let active = Self.activeWordIndex(time: time, words: words)
        let progress = active >= 0 ? SceneEvaluator.smootherstep((time - words[active].start) / max(0.001, style.wordFade)) : 0
        return CaptionState(cueID: cue.id, text: cue.text, words: style.highlight == .none ? [] : words,
                            activeWord: style.highlight == .none ? -1 : active, wordProgress: progress,
                            alpha: alpha, offset: entrance.offset, scale: entrance.scale,
                            headClipped: chosen.span.headClipped, tailClipped: chosen.span.tailClipped)
    }

    /// 入场：淡入只改不透明度，上浮加一点位移，弹跳用回弹曲线。
    static func captionEntrance(style: CaptionStyle, elapsed: Double) -> (offset: Double, scale: Double) {
        switch style.animation {
        case .none, .fade: return (0, 1)
        case .rise:
            let t = min(1, max(0, elapsed / 0.22))
            let eased = TextSegment.outBack(t)
            return ((1 - eased) * 0.022, 1)
        case .bounce:
            let t = min(1, max(0, elapsed / 0.28))
            return (0, 0.86 + 0.14 * TextSegment.outBack(t))
        }
    }

    /// 把一句的词投影到成片时间，并算出每个词在整句文本里的字符范围。
    /// 没有可用词边界时按字符数在句内均分——中文的词级时间戳常常整句只有一两段，这个兜底是常态而不是例外。
    static func renderWords(cue: CaptionCue, span: CaptionSpan, style: CaptionStyle) -> [CaptionRenderWord] {
        let source = cue.words ?? []
        let usable = source.filter { $0.end > span.sourceLower && $0.start < span.sourceUpper }
        let characters = Array(cue.text)
        if !usable.isEmpty, !style.evenSplit || usable.count >= max(2, characters.count / 6) {
            var result: [CaptionRenderWord] = []
            var cursor = 0
            for word in usable {
                let lower = max(word.start, span.sourceLower), upper = min(word.end, span.sourceUpper)
                guard upper > lower - 0.000_001 else { continue }
                // 词表的文本要落回整句里的位置，渲染才知道给哪几个字上色。
                let location = Self.locate(word.text, in: characters, from: cursor)
                let length = location >= 0 ? word.text.count : 0
                if location >= 0 { cursor = location + length }
                result.append(CaptionRenderWord(text: word.text,
                                                start: span.start + (lower - span.sourceLower),
                                                end: span.start + (upper - span.sourceLower),
                                                location: max(0, location), length: length))
            }
            if !result.isEmpty { return result }
        }
        guard !characters.isEmpty, span.duration > 0 else { return [] }
        let count = characters.count
        return (0..<count).map { index in
            CaptionRenderWord(text: String(characters[index]),
                              start: span.start + span.duration * Double(index) / Double(count),
                              end: span.start + span.duration * Double(index + 1) / Double(count),
                              location: index, length: 1)
        }
    }

    /// 在整句里找这个词的位置；找不到返回 -1。
    static func locate(_ word: String, in characters: [Character], from cursor: Int) -> Int {
        let needle = Array(word)
        guard !needle.isEmpty, cursor <= characters.count else { return -1 }
        var index = cursor
        while index + needle.count <= characters.count {
            if Array(characters[index..<(index + needle.count)]) == needle { return index }
            index += 1
        }
        return -1
    }

    /// 当前正在念的词；二分查找，长句也不会逐词扫描。
    static func activeWordIndex(time: Double, words: [CaptionRenderWord]) -> Int {
        var low = 0, high = words.count - 1, answer = -1
        while low <= high {
            let middle = (low + high) / 2
            if time >= words[middle].start - 0.000_001 { answer = middle; low = middle + 1 } else { high = middle - 1 }
        }
        return answer
    }

    /// 时间线上的拖动：整体平移连词一起挪，拖两端只改这一句的范围。字幕不会被固定到成片时间。
    public mutating func dragCaption(id: UUID, edge: FocusDragEdge, delta: Double, sourceDuration: Double) {
        guard delta.isFinite, sourceDuration.isFinite, sourceDuration > 0 else { return }
        var list = captionList
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        var cue = list[index]
        let pinned = cue.timelineStart != nil
        let limit = pinned ? max(duration, cue.sourceDuration) : sourceDuration
        let start = cue.timelineStart ?? cue.sourceStart
        let length = cue.sourceDuration
        guard start.isFinite, length > 0 else { return }
        let minimum = min(0.2, limit)
        switch edge {
        case .body:
            let moved = min(max(0, limit - length), max(0, start + delta))
            if pinned { cue.timelineStart = moved } else {
                let shift = moved - cue.sourceStart
                cue.sourceStart = moved; cue.sourceEnd = moved + length
                // 词表也是源时间，跟着一起挪；不挪的话高亮会和句子错开。
                cue.words = cue.words?.map { CaptionWord(start: $0.start + shift, end: $0.end + shift, text: $0.text) }
            }
        case .leading:
            let end = cue.sourceEnd
            cue.sourceStart = min(end - minimum, max(0, cue.sourceStart + delta))
        case .trailing:
            cue.sourceEnd = min(limit, max(cue.sourceStart + minimum, cue.sourceEnd + delta))
        }
        list[index] = cue; captionList = list
    }

    /// 分割一句：按源时间切成两句，文本按字符比例分开，词表各归各。
    @discardableResult public mutating func splitCaption(id: UUID, atSource time: Double) -> UUID? {
        guard let cue = caption(id: id), time > cue.sourceStart + 0.05, time < cue.sourceEnd - 0.05 else { return nil }
        let characters = Array(cue.text)
        // 一个字都没有（用户把文本清空了）或者只剩一个字：切不出两句，直接不切。
        // 少了这道 guard，下面的 characters[0..<cut] 会数组越界，整个 App 当场退出。
        guard characters.count >= 2 else { return nil }
        let ratio = (time - cue.sourceStart) / cue.sourceDuration
        // 有词表时按词边界切，切得比按比例准得多。
        var cut = Int((Double(characters.count) * ratio).rounded())
        if let words = cue.words, let boundary = words.last(where: { $0.start <= time }) {
            let located = Self.locate(boundary.text, in: characters, from: 0)
            if located >= 0 { cut = located + boundary.text.count }
        }
        cut = max(1, min(characters.count - 1, cut))
        var head = cue, tail = cue
        head.sourceEnd = time; head.text = String(characters[0..<cut])
        head.words = cue.words?.filter { $0.start < time }
        tail.id = UUID(); tail.sourceStart = time; tail.text = String(characters[cut...])
        tail.words = cue.words?.filter { $0.start >= time }
        tail.timelineStart = cue.timelineStart.map { $0 + (time - cue.sourceStart) }
        var list = captionList
        guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
        list.replaceSubrange(index...index, with: [head, tail])
        captionList = list
        return tail.id
    }

    /// 合并相邻两句：后一句并入前一句。
    public mutating func mergeCaption(id: UUID, with next: UUID) {
        var list = captionList
        guard let first = list.firstIndex(where: { $0.id == id }), let second = list.firstIndex(where: { $0.id == next }),
              first != second else { return }
        var merged = list[first]
        let other = list[second]
        merged.sourceStart = min(merged.sourceStart, other.sourceStart)
        merged.sourceEnd = max(merged.sourceEnd, other.sourceEnd)
        // 合并后可能超过单句上限，截断而不是让整笔编辑在校验时被拒。
        merged.text = String((merged.text + other.text).prefix(CaptionCue.textLimit))
        merged.words = ((merged.words ?? []) + (other.words ?? [])).sorted { $0.start < $1.start }
        if merged.words?.isEmpty == true { merged.words = nil }
        list[first] = merged
        list.remove(at: second)
        captionList = list
    }

    /// 导入外部字幕：导入的内容说了算，与它在源时间上重叠的旧句子让位；不重叠的旧句子保留。
    /// 不能反过来（保留旧句、追加新句），那会让同一段话变成两条，导出时每句输出两遍。
    public mutating func mergeImportedCaptions(_ fresh: [CaptionCue]) {
        guard !fresh.isEmpty else { return }
        let kept = captionList.filter { existing in
            !fresh.contains { $0.sourceStart < existing.sourceEnd - 0.001 && existing.sourceStart < $0.sourceEnd - 0.001 }
        }
        captionList = (kept + fresh).sorted { $0.sourceStart < $1.sourceStart }
    }

    /// 重新转写：保护用户改过的句子，新结果里与它们重叠的部分丢掉。
    public mutating func mergeTranscription(_ fresh: [CaptionCue]) {
        let locked = captionList.filter { $0.locked }
        let kept = fresh.filter { candidate in
            !locked.contains { $0.sourceStart < candidate.sourceEnd - 0.001 && candidate.sourceStart < $0.sourceEnd - 0.001 }
        }
        captionList = (locked + kept).sorted { $0.sourceStart < $1.sourceStart }
    }

    public func captionNumbers() -> [UUID: Int] {
        let list = captionList.sorted { $0.sourceStart < $1.sourceStart }
        return Dictionary(uniqueKeysWithValues: list.enumerated().map { ($0.element.id, $0.offset + 1) })
    }
}

/// 字幕文件的读写。时间一律是**成片时间**，因为那才是观众看到的时间轴。
public enum CaptionFile {
    /// 导出 SRT。被剪断的一句会输出成多条；成片上恰好相邻（间隔小于 0.08 秒）的两段并回一条。
    public static func srt(_ edit: VideoEdit) -> String { serialize(edit, vtt: false) }
    /// 导出 WebVTT。
    public static func vtt(_ edit: VideoEdit) -> String { "WEBVTT\n\n" + serialize(edit, vtt: true) }

    static func serialize(_ edit: VideoEdit, vtt: Bool) -> String {
        let style = edit.captionStyleOrDefault
        let spans = edit.captionSpans()
        var merged: [CaptionSpan] = []
        for span in spans {
            if let last = merged.last, last.cueID == span.cueID, span.start - last.end < 0.08 {
                merged[merged.count - 1] = CaptionSpan(cueID: last.cueID, clipID: last.clipID, start: last.start,
                                                       duration: span.end - last.start,
                                                       sourceLower: last.sourceLower, sourceUpper: span.sourceUpper,
                                                       headClipped: last.headClipped, tailClipped: span.tailClipped)
            } else { merged.append(span) }
        }
        var lines: [String] = []
        for (number, span) in merged.enumerated() {
            guard let cue = edit.caption(id: span.cueID), !cue.text.isEmpty else { continue }
            let range = edit.captionDisplayRange(span, style: style,
                                                 nextStart: number + 1 < merged.count ? merged[number + 1].start : nil)
            let text = (span.headClipped ? "…" : "") + cue.text + (span.tailClipped ? "…" : "")
            lines.append("\(lines.count + 1)\n\(time(range.lowerBound, vtt: vtt)) --> \(time(range.upperBound, vtt: vtt))\n\(text)\n")
        }
        return lines.joined(separator: "\n")
    }

    static func time(_ value: Double, vtt: Bool) -> String {
        let total = Int((max(0, value) * 1000).rounded())
        let hours = total / 3_600_000, minutes = (total / 60_000) % 60, seconds = (total / 1000) % 60, millis = total % 1000
        return String(format: "%02d:%02d:%02d\(vtt ? "." : ",")%03d", hours, minutes, seconds, millis)
    }

    /// 读 SRT / VTT。时间被当作**成片时间**换算回源时间；换不回去的（落在被剪掉的区间里）丢弃。
    /// 导入的句子一律标成 `locked`，重新转写不会把它们冲掉。
    public static func parse(_ text: String, into edit: VideoEdit) -> [CaptionCue] {
        var result: [CaptionCue] = []
        let index = TimelineIndex(clips: edit.orderedScreenClips)
        // 源时间的上界：外部字幕（包括 Caplo 自己导出的那份，最后一句会带上"说完停留"）
        // 常常比片子长一点点。不夹住的话最后一条会越界，整批导入在校验时被拒——
        // 用户看到的是"版本不支持"，几百句一条都进不来。
        let sourceLimit = edit.orderedScreenClips.map { $0.sourceStart + $0.playableDuration }.max() ?? 0
        // 换行统一成 \n（含旧式 \r）、去掉 BOM，按"空白行"分块：只认连续两个换行的话，
        // 用带空格的空行或旧式回车分隔的文件会把两句并成一句。
        let normalized = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var blocks: [[String]] = [], current: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { blocks.append(current); current = [] }
            } else { current.append(line) }
        }
        if !current.isEmpty { blocks.append(current) }
        for rows in blocks {
            guard let arrow = rows.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = rows[arrow].components(separatedBy: "-->")
            // VTT 的时间行后面可以跟显示设置（align:start position:10% 等）：只取箭头两侧紧挨着的那个时间。
            let left = parts.first?.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            let right = parts.count == 2 ? (parts[1].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "") : ""
            guard parts.count == 2, let from = seconds(left), let to = seconds(right), to > from else { continue }
            let body = rows[(arrow + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            guard let sourceStart = index.sourceTime(at: from), sourceStart < sourceLimit else { continue }
            let mapped = index.sourceTime(at: max(from + 0.05, to - 0.001)) ?? (sourceStart + (to - from))
            let sourceEnd = min(mapped, sourceLimit)
            guard sourceEnd > sourceStart + 0.02 else { continue }
            var cue = CaptionCue(sourceStart: sourceStart, sourceEnd: sourceEnd, text: String(body.prefix(CaptionCue.textLimit)))
            cue.locked = true
            result.append(cue)
        }
        return result.sorted { $0.sourceStart < $1.sourceStart }
    }

    static func seconds(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = trimmed.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let values = parts.compactMap { Double($0) }
        guard values.count == parts.count else { return nil }
        return parts.count == 3 ? values[0] * 3600 + values[1] * 60 + values[2] : values[0] * 60 + values[1]
    }
}

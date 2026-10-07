import Foundation
import CoreGraphics

/// 文字层：盖在成片之上的一段文字，带排版、外观与进出动画。
///
/// 与遮罩共用两条约定：时间存在**源素材域**（剪一刀自己裂成两段），字号等尺寸按 **1080 参考高度**书写，
/// 导出到任何分辨率都等比缩放。不同的是坐标：文字定位在**输出画面**上，不跟着镜头推近一起放大——
/// 标题被推出画外没有任何意义。
public struct TextSegment: Codable, Equatable, Sendable, Identifiable {
    /// 版式。`overlay` 盖在画面上；其余三种会把画面层整体缩小、挪位或淡出。
    public enum Layout: String, Codable, CaseIterable, Sendable {
        case overlay, fullscreen, splitLeft, splitRight
        public var title: String {
            switch self { case .overlay: String(localized: "叠加"); case .fullscreen: String(localized: "全屏"); case .splitLeft: String(localized: "左分屏"); case .splitRight: String(localized: "右分屏") }
        }
        /// 分屏时文字占哪半边；`nil` 表示不分屏。
        public var textOnLeft: Bool? {
            switch self { case .splitLeft: true; case .splitRight: false; default: nil }
        }
    }
    public enum Animation: String, Codable, CaseIterable, Sendable { case none, fade, slideUp, slideDown, pop, type }
    public enum Family: String, Codable, CaseIterable, Sendable { case system, sans, serif, rounded, mono }
    public enum Alignment: String, Codable, CaseIterable, Sendable { case leading, center, trailing }
    /// 文字色：七个预设格加自定义色。预设存名字，自定义存 `#RRGGBB`，工程文件里都是一个字符串。
    /// 早先还有个「自动」——按**画布背景**亮度在黑白之间选。它判的是背景，不是文字实际压着的画面，
    /// 边距为 0 时背景根本露不出来，于是白字压在浅色录屏上只剩一团投影。已删除，旧工程见
    /// `VideoEdit.resolveLegacyAutoTextColors()`。
    public struct Palette: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let white = Palette(rawValue: "white")
        public static let ink = Palette(rawValue: "ink")
        public static let mist = Palette(rawValue: "mist")
        public static let sky = Palette(rawValue: "sky")
        public static let mint = Palette(rawValue: "mint")
        public static let amber = Palette(rawValue: "amber")
        public static let rose = Palette(rawValue: "rose")
        /// 面板上固定的七格，顺序即展示顺序。
        public static let presets: [Palette] = [.white, .ink, .mist, .sky, .mint, .amber, .rose]

        /// 自定义色。分量按 0…1 收进 `#RRGGBB`。
        public init(red: Double, green: Double, blue: Double) {
            func byte(_ value: Double) -> Int { Int((min(1, max(0, value.isFinite ? value : 0)) * 255).rounded()) }
            rawValue = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        }

        public var isCustom: Bool { Self.components(rawValue) != nil }
        /// 认得出来的色才算数：七个预设名或一个合法的 `#RRGGBB`。
        public var isValid: Bool { isCustom || Self.presets.contains(self) }

        /// 0…1 的 sRGB 分量。认不出来的（含旧工程残留的 `auto`）一律当白，不至于画不出东西。
        public var rgb: (Double, Double, Double) {
            if let custom = Self.components(rawValue) { return custom }
            switch rawValue {
            case "ink": return (0.086, 0.086, 0.102)
            case "mist": return (0.910, 0.902, 0.933)
            case "sky": return (0.675, 0.812, 1)
            case "mint": return (0.596, 0.925, 0.816)
            case "amber": return (1, 0.816, 0.541)
            case "rose": return (1, 0.522, 0.545)
            default: return (1, 1, 1)
            }
        }

        public var title: String {
            switch rawValue {
            case "white": String(localized: "白"); case "ink": String(localized: "墨"); case "mist": String(localized: "雾"); case "sky": String(localized: "天蓝")
            case "mint": String(localized: "薄荷"); case "amber": String(localized: "琥珀"); case "rose": String(localized: "玫瑰")
            default: isCustom ? rawValue : String(localized: "白")
            }
        }

        /// 工程文件里存的一直是一个字符串，换成结构体之后也不能变。
        public init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        private static func components(_ value: String) -> (Double, Double, Double)? {
            guard value.count == 7, value.hasPrefix("#"),
                  let number = Int(value.dropFirst(), radix: 16) else { return nil }
            return (Double((number >> 16) & 0xFF) / 255, Double((number >> 8) & 0xFF) / 255, Double(number & 0xFF) / 255)
        }
    }

    public var id = UUID()
    public var start: Double
    public var duration: Double
    /// 非空表示固定到成片时间，不再跟随剪辑。
    public var timelineStart: Double?
    public var text: String = ""
    /// 新建时用的预设名，只用于显示（时间线块名、面板里的选中格）。
    public var preset: String?
    public var layout: Layout = .overlay
    /// 画面层从常态变到全屏 / 分屏所用的时间，两端各一次。
    public var layoutTransition: Double = 0.35
    /// 分栏间距（960 参考宽）的默认值：不留间距，两栏各自贴着自己的安全边。
    public static let defaultSplitGap: Double = 0
    /// 分屏时画面占两栏可用宽度的默认比例：画面拿四分之三，文字占一栏。
    public static let defaultSplitRatio: Double = 0.75
    /// 分栏间距（960 参考宽），只有分屏用得上。
    public var splitGap: Double = TextSegment.defaultSplitGap
    /// 分屏时画面占两栏可用宽度的比例（0.25…0.75），剩下的给文字。0.5 是等分，默认 0.75 让画面占大头。
    public var splitRatio: Double = TextSegment.defaultSplitRatio
    /// 旧版"全屏卡段"留下的字段：指向那条定格片段。读取时由 `VideoEdit.migrateLegacyHoldCards()` 换成卡片
    /// （`VideoClip.card`），之后恒为 nil、不再写出。
    public var holdClipID: UUID?

    // MARK: 排版（尺寸都按 1080 参考高度）
    public var size: Double = 96
    public var weight: Double = 700
    public var family: Family = .system
    public var alignment: Alignment = .center
    public var lineHeight: Double = 1.15
    public var tracking: Double = 0
    /// 锚点，文字盒内归一化（左上原点）。左对齐时 x 是左边缘，居中是中线，右对齐是右边缘；y 恒为整块文字的垂直中心。
    public var x: Double = 0.5
    public var y: Double = 0.5
    /// 最大行宽，占文字盒宽度的比例。
    public var maxWidth: Double = 0.8

    // MARK: 外观
    public var color: Palette = .white
    public var opacity: Double = 1
    public var plate = false
    public var plateColor: Palette = .ink
    public var plateOpacity: Double = 0.55
    public var platePadding: Double = 16
    public var plateRadius: Double = 8
    /// 底板横贯整个文字盒（字幕条常用），而不是只包住文字。
    public var shadow = false
    public var shadowOpacity: Double = 0.45
    public var shadowBlur: Double = 18
    public var shadowOffset: Double = 6

    // MARK: 时序
    public var enterKind: Animation = .fade
    public var enterDuration: Double = 0.4
    public var exitKind: Animation = .fade
    public var exitDuration: Double = 0.35
    public var enabled = true
    public var title: String?

    // MARK: 常量

    public static let sizeRange: ClosedRange<Double> = 12...240
    public static let weightRange: ClosedRange<Double> = 300...900
    /// 承载文字的宽度占文字盒的比例。上限 1 是关键：分屏时文字盒就是那一栏，
    /// 存成比例它就永远越不出这一栏，换版式也不用重算。
    public static let maxWidthRange: ClosedRange<Double> = 0.2...1
    /// 上滑 / 下滑的位移量，占画面高度的比例。
    public static let slide: Double = 0.06
    /// 一段文字最多这么多字符；再多就不是"文字层"而是字幕了。
    public static let textLimit = 2000

    public init(start: Double, duration: Double, text: String = "") {
        self.start = start; self.duration = duration; self.text = text
    }

    // MARK: 编解码
    //
    // 手写解码而不是让编译器合成：合成的解码器**不认属性上的默认值**，缺一个键就抛 keyNotFound，
    // 整份工程连带作废（用户看到的是一句"编辑数据版本不支持或内容无效"）。
    // 这个类型每加一个新参数（版式、分栏间距、画面占比……）都会让之前存下的工程少一个键，
    // 所以除了起止时间之外一律 decodeIfPresent + 默认值。CameraLayout 早就是这么写的。
    private enum CodingKeys: String, CodingKey {
        case id, start, duration, timelineStart, text, preset, layout, layoutTransition, splitGap, splitRatio, holdClipID
        case size, weight, family, alignment, lineHeight, tracking, x, y, maxWidth
        case color, opacity, plate, plateColor, plateOpacity, platePadding, plateRadius
        case shadow, shadowOpacity, shadowBlur, shadowOffset
        case enterKind, enterDuration, exitKind, exitDuration, enabled, title
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try box.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        start = try box.decode(Double.self, forKey: .start)
        duration = try box.decode(Double.self, forKey: .duration)
        id = try value(.id, UUID())
        timelineStart = try box.decodeIfPresent(Double.self, forKey: .timelineStart)
        text = try value(.text, "")
        preset = try box.decodeIfPresent(String.self, forKey: .preset)
        layout = try value(.layout, Layout.overlay)
        layoutTransition = try value(.layoutTransition, 0.35)
        splitGap = try value(.splitGap, Self.defaultSplitGap)
        splitRatio = try value(.splitRatio, Self.defaultSplitRatio)
        holdClipID = try box.decodeIfPresent(UUID.self, forKey: .holdClipID)
        size = try value(.size, 96)
        weight = try value(.weight, 700)
        family = try value(.family, Family.system)
        alignment = try value(.alignment, Alignment.center)
        lineHeight = try value(.lineHeight, 1.15)
        tracking = try value(.tracking, 0)
        x = try value(.x, 0.5)
        y = try value(.y, 0.5)
        maxWidth = try value(.maxWidth, 0.8)
        color = try value(.color, Palette.white)
        opacity = try value(.opacity, 1)
        plate = try value(.plate, false)
        plateColor = try value(.plateColor, Palette.ink)
        plateOpacity = try value(.plateOpacity, 0.55)
        platePadding = try value(.platePadding, 16)
        plateRadius = try value(.plateRadius, 8)
        shadow = try value(.shadow, false)
        shadowOpacity = try value(.shadowOpacity, 0.45)
        shadowBlur = try value(.shadowBlur, 18)
        shadowOffset = try value(.shadowOffset, 6)
        enterKind = try value(.enterKind, Animation.fade)
        enterDuration = try value(.enterDuration, 0.4)
        exitKind = try value(.exitKind, Animation.fade)
        exitDuration = try value(.exitDuration, 0.35)
        enabled = try value(.enabled, true)
        title = try box.decodeIfPresent(String.self, forKey: .title)
    }

    public var displayTitle: String { title ?? defaultTitle(number: nil) }
    public func defaultTitle(number: Int?) -> String {
        let name = preset ?? (text.isEmpty ? String(localized: "文字") : String(text.prefix(8)).replacingOccurrences(of: "\n", with: " "))
        return number.map { "\(name) \($0)" } ?? name
    }

    /// 进出时长之和超过本段时长时按比例压缩，两端各自还剩一点，不会出现"进场没走完就开始退场"。
    public var timings: (enter: Double, exit: Double) {
        let enter = max(0, enterDuration), exit = max(0, exitDuration)
        guard enter + exit > duration, enter + exit > 0 else { return (enter, exit) }
        let scale = duration / (enter + exit)
        return (enter * scale, exit * scale)
    }

    var isValid: Bool {
        guard start.isFinite, start >= 0, duration.isFinite, duration > 0,
              text.count <= Self.textLimit,
              size.isFinite, Self.sizeRange.contains(size),
              weight.isFinite, Self.weightRange.contains(weight),
              lineHeight.isFinite, (0.6...2.5).contains(lineHeight),
              tracking.isFinite, (-10...40).contains(tracking),
              x.isFinite, y.isFinite, (-0.5...1.5).contains(x), (-0.5...1.5).contains(y),
              maxWidth.isFinite, (0.05...1).contains(maxWidth),
              opacity.isFinite, (0...1).contains(opacity),
              plateOpacity.isFinite, (0...1).contains(plateOpacity),
              platePadding.isFinite, (0...200).contains(platePadding),
              plateRadius.isFinite, (0...120).contains(plateRadius),
              shadowOpacity.isFinite, (0...1).contains(shadowOpacity),
              shadowBlur.isFinite, (0...120).contains(shadowBlur),
              shadowOffset.isFinite, (-80...80).contains(shadowOffset),
              enterDuration.isFinite, (0...5).contains(enterDuration),
              exitDuration.isFinite, (0...5).contains(exitDuration),
              layoutTransition.isFinite, (0...3).contains(layoutTransition),
              splitGap.isFinite, (0...240).contains(splitGap),
              splitRatio.isFinite, TextSegment.splitRatioRange.contains(splitRatio),
              (timelineStart.map { $0.isFinite && $0 >= 0 } ?? true) else { return false }
        return true
    }
}

/// 一段文字在成片时间轴上的一段。与遮罩一样，被剪辑切开时会有多段。
public struct TextSpan: Sendable, Hashable {
    public let textID: UUID
    public let clipID: UUID?
    public let start: Double
    public let duration: Double
    /// 这一段的起点对应文字自身的第几秒；动画相位要用它，否则剪辑之后进场动画会重放。
    public let offset: Double
    /// 这一段画的是"保持末帧"的定格：动画相位不往前走，停在 `offset` 那一刻。
    public var frozen = false
    public var end: Double { start + duration }
}

/// 某一时刻文字的动画状态。
public struct TextAnimationState: Equatable, Sendable {
    /// 不透明度倍数（还要再乘上这段文字自己的 opacity）。
    public var alpha: Double = 1
    /// 垂直位移，占画面高度的比例；正值向下。
    public var offset: Double = 0
    public var scale: Double = 1
    /// 打字机已显示的比例 0…1。
    public var reveal: Double = 1
    public init(alpha: Double = 1, offset: Double = 0, scale: Double = 1, reveal: Double = 1) {
        self.alpha = alpha; self.offset = offset; self.scale = scale; self.reveal = reveal
    }
}

/// 某一时刻要画的一段文字：静态参数加动画状态。渲染与画布编辑共用。
public struct TextState: Equatable, Sendable {
    public var id: UUID
    public var segment: TextSegment
    public var animation: TextAnimationState
    /// 这一刻实际要显示的字数（打字机用；其余等于全文长度）。
    public var revealedCount: Int
    public init(id: UUID, segment: TextSegment, animation: TextAnimationState, revealedCount: Int) {
        self.id = id; self.segment = segment; self.animation = animation; self.revealedCount = revealedCount
    }
}

extension TextSegment {
    /// 本段内已过 `elapsed` 秒时的动画状态。
    public func animation(elapsed: Double) -> TextAnimationState {
        let (enter, exit) = timings
        if enter > 0, elapsed < enter { return Self.enterState(enterKind, progress: elapsed / enter) }
        if exit > 0, elapsed > duration - exit { return Self.exitState(exitKind, progress: (elapsed - (duration - exit)) / exit) }
        return TextAnimationState()
    }

    /// 「快显慢移」：透明度在入场的前三分之一就走完，剩下的时间只走位移。
    /// 整块文字位图（字形连同阴影）是被统一乘以透明度的，所以半透明的中间态既没有终态的白、
    /// 也没有阴影托底——压在浅色画面上就是一片灰。把这段中间态压到两三帧，灰就看不出来了。
    static func frontLoaded(_ eased: Double) -> Double { min(1, eased * 2.8) }

    static func enterState(_ kind: Animation, progress: Double) -> TextAnimationState {
        let t = min(1, max(0, progress))
        switch kind {
        case .none: return TextAnimationState()
        case .fade: return TextAnimationState(alpha: SceneEvaluator.smootherstep(t))
        case .slideUp:
            let eased = SceneEvaluator.smootherstep(t)
            return TextAnimationState(alpha: Self.frontLoaded(eased), offset: (1 - eased) * TextSegment.slide)
        case .slideDown:
            let eased = SceneEvaluator.smootherstep(t)
            return TextAnimationState(alpha: Self.frontLoaded(eased), offset: -(1 - eased) * TextSegment.slide)
        case .pop:
            // 回弹峰值约 1.0999，缩放峰值 ≈ 1.028：看得见但不夸张。
            return TextAnimationState(alpha: min(1, t * 2.2), scale: 0.72 + 0.28 * Self.outBack(t))
        case .type: return TextAnimationState(reveal: t)
        }
    }

    static func exitState(_ kind: Animation, progress: Double) -> TextAnimationState {
        let q = min(1, max(0, progress))
        switch kind {
        case .none: return TextAnimationState()
        case .fade: return TextAnimationState(alpha: 1 - SceneEvaluator.smootherstep(q))
        case .slideUp:
            let eased = SceneEvaluator.smootherstep(q)
            return TextAnimationState(alpha: 1 - eased, offset: -eased * TextSegment.slide)
        case .slideDown:
            let eased = SceneEvaluator.smootherstep(q)
            return TextAnimationState(alpha: 1 - eased, offset: eased * TextSegment.slide)
        case .pop: return TextAnimationState(alpha: 1 - pow(q, 1.5), scale: 1 - 0.28 * Self.inBack(q))
        case .type: return TextAnimationState(reveal: 1 - q)
        }
    }

    static func outBack(_ t: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1, u = t - 1
        return 1 + c3 * u * u * u + c1 * u * u
    }
    static func inBack(_ t: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return c3 * t * t * t - c1 * t * t
    }
}

extension VideoEdit {
    /// 文字层列表的非可选视图；写入后重算版本号。
    public var textList: [TextSegment] {
        get { texts ?? [] }
        set { texts = newValue.isEmpty ? nil : newValue; normalizeSchemaVersion() }
    }
    public mutating func addText(_ value: TextSegment) { textList.append(value) }
    public mutating func removeText(id: UUID) { textList.removeAll { $0.id == id } }
    /// 改一段文字。卡片里的那段文字也走这里（面板、画布拖动共用一套），只是时间与版式由卡片决定、改了也不算数。
    public mutating func updateText(id: UUID, _ change: (inout TextSegment) -> Void) {
        var list = textList
        guard let index = list.firstIndex(where: { $0.id == id }) else {
            if let card = cardID(forText: id) { updateCard(id: card) { change(&$0.text) } }
            return
        }
        change(&list[index]); textList = list
    }
    /// 按 ID 找文字；找不到再看是不是某块卡片里的文字（时间换成卡片在成片上的起止）。
    public func text(id: UUID) -> TextSegment? {
        if let value = textList.first(where: { $0.id == id }) { return value }
        return clips.first { $0.card?.text.id == id }.flatMap(cardText)
    }

    /// 在成片某一时刻新建文字，时间换算回源素材域。
    @discardableResult
    public mutating func insertText(at time: Double, duration wanted: Double = 3, sourceDuration: Double,
                                    preset: TextPreset = .title, text: String = "") -> UUID? {
        guard time.isFinite, sourceDuration.isFinite, sourceDuration > 0 else { return nil }
        let clamped = max(0, min(time, max(0, self.duration - 0.00001)))
        // 停在卡片上：卡片没有源时刻，这段文字钉在成片时间上（卡片自己的字在卡片里改，这里是再叠一段）。
        if let card = card(atTimeline: clamped) {
            let anchor = max(0, min(time, (card.timelineStart ?? 0) + card.duration - 1.0 / 30))
            var value = preset.segment(start: 0, duration: max(1.0 / 30, min(wanted, self.duration - anchor)))
            value.text = text.isEmpty ? preset.sample : text
            value.timelineStart = anchor
            addText(value)
            return value.id
        }
        // 与遮罩同理：播放头在时间线空白处时映射不出源时间，不能拿成片秒数顶替。
        guard let source = sourceTime(at: clamped) else { return nil }
        let start = max(0, min(source, max(0, sourceDuration - 1.0 / 30)))
        var value = preset.segment(start: start, duration: max(1.0 / 30, min(wanted, sourceDuration - start)))
        value.text = text.isEmpty ? preset.sample : text
        addText(value)
        return value.id
    }

    /// 文字在成片时间轴上的可见段。与遮罩同构：保持末帧的那段画面上仍然应该有标题，
    /// 但那一截是**冻住**的（见 `projectSource`）——否则在定格画面里，源域的文字会被拉伸重放一遍。
    public func textSpans(in range: Range<Double>? = nil, using existingIndex: TimelineIndex? = nil) -> [TextSpan] {
        let index = existingIndex ?? TimelineIndex(clips: orderedScreenClips)
        let visible = range ?? 0..<duration
        var result: [TextSpan] = []
        for value in textList where value.enabled {
            if let start = value.timelineStart {
                if start < visible.upperBound && start + value.duration > visible.lowerBound {
                    result.append(TextSpan(textID: value.id, clipID: nil, start: start, duration: value.duration, offset: 0))
                }
                continue
            }
            let low = value.start, high = value.start + value.duration
            // 与遮罩同一套：按真正可见的段投影，被盖住的素材上的文字不出现。
            for span in index.visibleSpans(in: visible) {
                let clip = index.clips[span.index]
                let base = index.boundaries[span.index]
                for piece in Self.projectSource(low: low, high: high, clip: clip, base: base,
                                                spanStart: span.start, spanEnd: span.end) {
                    guard piece.start < visible.upperBound, piece.start + piece.duration > visible.lowerBound else { continue }
                    result.append(TextSpan(textID: value.id, clipID: clip.id, start: piece.start,
                                           duration: piece.duration, offset: piece.offset, frozen: piece.frozen))
                }
            }
        }
        return result
    }

    /// 这一刻要画的文字，按数组顺序（后加的盖在上面）。卡片的文字排在最前，压在普通文字之下。
    public func activeTexts(at time: Double, spans: [TextSpan]? = nil) -> [TextState] {
        let cards = clips.contains { $0.card != nil } ? cardTextStates(at: time) : []
        guard !textList.isEmpty else { return cards }
        let all = spans ?? textSpans()
        return cards + textList.compactMap { value in
            guard value.enabled, !value.text.isEmpty else { return nil }
            guard let span = all.first(where: { $0.textID == value.id && time >= $0.start && time < $0.end }) else { return nil }
            // 动画相位按文字自身的时间算：剪辑把它切成两段，第二段不会重放进场动画。
            let elapsed = span.frozen ? span.offset : min(max(0, time - span.start), span.duration) + span.offset
            let animation = value.animation(elapsed: elapsed)
            let count = value.text.count
            let revealed = animation.reveal >= 1 ? count : max(0, min(count, Int((Double(count) * animation.reveal).rounded())))
            // 打字机刚开始时一个字都没揭出来，这一帧仍然要算进去：底板与阴影已经在场，
            // 跳过这一帧会让底板闪一下。
            guard animation.alpha > 0.001 else { return nil }
            return TextState(id: value.id, segment: value, animation: animation, revealedCount: revealed)
        }
    }

    /// 文字编号：只有一段时不编号；多段按在时间线上首次出现的位置排序。
    public func textNumbers(using spans: [TextSpan]? = nil) -> [UUID: Int] {
        let list = textList
        guard list.count > 1 else { return [:] }
        var firstStart: [UUID: Double] = [:]
        for span in spans ?? textSpans() { firstStart[span.textID] = min(firstStart[span.textID] ?? .infinity, span.start) }
        let ordered = list.enumerated().sorted { a, b in
            let x = firstStart[a.element.id] ?? (a.element.timelineStart ?? a.element.start)
            let y = firstStart[b.element.id] ?? (b.element.timelineStart ?? b.element.start)
            return x == y ? a.offset < b.offset : x < y
        }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.element.id, $0.offset + 1) })
    }
    public func textDisplayTitle(_ value: TextSegment, numbers: [UUID: Int]? = nil) -> String {
        value.title ?? value.defaultTitle(number: (numbers ?? textNumbers())[value.id])
    }

    /// 时间线上的拖动。与遮罩同理，绝不因为拖动就把文字固定到成片时间。
    public mutating func dragText(id: UUID, edge: FocusDragEdge, delta: Double, sourceDuration: Double) {
        guard delta.isFinite, sourceDuration.isFinite, sourceDuration > 0 else { return }
        var list = textList
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        var value = list[index]
        let pinned = value.timelineStart != nil
        let limit = pinned ? max(duration, value.duration) : sourceDuration
        let start = value.timelineStart ?? value.start
        guard start.isFinite, value.duration.isFinite, value.duration > 0 else { return }
        let minimum = min(0.2, limit)
        switch edge {
        case .body:
            let moved = min(max(0, limit - value.duration), max(0, start + delta))
            if pinned { value.timelineStart = moved } else { value.start = moved }
        case .leading:
            let end = start + value.duration
            let next = min(end - minimum, max(0, start + delta))
            if pinned { value.timelineStart = next } else { value.start = next }
            value.duration = end - next
        case .trailing:
            value.duration = min(limit - start, max(minimum, value.duration + delta))
        }
        list[index] = value; textList = list
    }
}

/// 八个内置预设。字号按 1080p 书写。
public enum TextPreset: String, CaseIterable, Sendable, Identifiable {
    case title, subtitle, lowerThird, eyebrow, bigNumber, quote, code, typewriter
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .title: String(localized: "标题"); case .subtitle: String(localized: "副标题"); case .lowerThird: String(localized: "字幕条"); case .eyebrow: String(localized: "眉题")
        case .bigNumber: String(localized: "大数字"); case .quote: String(localized: "引言"); case .code: String(localized: "代码"); case .typewriter: String(localized: "打字机")
        }
    }
    /// 面板格子里画的样例文字。
    public var sample: String {
        switch self {
        case .bigNumber: "3×"; case .code: "npm run build"; case .quote: String(localized: "少即是多")
        default: String(localized: "产品演示")
        }
    }

    public func segment(start: Double, duration: Double) -> TextSegment {
        var value = TextSegment(start: start, duration: duration)
        value.preset = name
        switch self {
        case .title:
            value.size = 96; value.weight = 700; value.alignment = .center; value.lineHeight = 1.15
            value.x = 0.5; value.y = 0.5; value.maxWidth = 0.8
            value.enterKind = .slideUp; value.enterDuration = 0.45; value.exitKind = .fade; value.exitDuration = 0.30
            value.shadow = true; value.shadowOpacity = 0.5; value.shadowBlur = 24; value.shadowOffset = 8
        case .subtitle:
            value.size = 44; value.weight = 500; value.alignment = .center; value.lineHeight = 1.30
            value.x = 0.5; value.y = 0.62; value.maxWidth = 0.72
            value.enterKind = .fade; value.enterDuration = 0.35; value.exitKind = .fade; value.exitDuration = 0.30
            value.shadow = true; value.shadowOpacity = 0.4; value.shadowBlur = 18; value.shadowOffset = 6
        case .lowerThird:
            value.size = 40; value.weight = 600; value.alignment = .leading; value.lineHeight = 1.25
            value.x = 0.22; value.y = 0.85; value.maxWidth = 0.6
            value.enterKind = .slideUp; value.enterDuration = 0.30; value.exitKind = .fade; value.exitDuration = 0.25
            value.plate = true; value.plateColor = .ink; value.plateOpacity = 0.55; value.platePadding = 20; value.plateRadius = 8
        case .eyebrow:
            value.size = 26; value.weight = 700; value.alignment = .leading; value.lineHeight = 1.2; value.tracking = 6
            value.x = 0.22; value.y = 0.78; value.maxWidth = 0.5
            value.enterKind = .fade; value.enterDuration = 0.25; value.exitKind = .fade; value.exitDuration = 0.20
        case .bigNumber:
            value.size = 160; value.weight = 800; value.alignment = .center; value.lineHeight = 1.0; value.tracking = -2
            value.x = 0.5; value.y = 0.5; value.maxWidth = 0.9
            value.enterKind = .pop; value.enterDuration = 0.50; value.exitKind = .fade; value.exitDuration = 0.30
            value.shadow = true; value.shadowOpacity = 0.55; value.shadowBlur = 28; value.shadowOffset = 10
        case .quote:
            value.size = 56; value.weight = 500; value.family = .serif
            value.alignment = .center; value.lineHeight = 1.45
            value.x = 0.5; value.y = 0.5; value.maxWidth = 0.7
            value.enterKind = .fade; value.enterDuration = 0.50; value.exitKind = .fade; value.exitDuration = 0.40
        case .code:
            value.size = 36; value.weight = 400; value.family = .mono; value.alignment = .leading; value.lineHeight = 1.5
            value.x = 0.12; value.y = 0.5; value.maxWidth = 0.76
            value.enterKind = .fade; value.enterDuration = 0.20; value.exitKind = .fade; value.exitDuration = 0.20
            value.plate = true; value.plateColor = .ink; value.plateOpacity = 0.90; value.platePadding = 24; value.plateRadius = 10
        case .typewriter:
            value.size = 44; value.weight = 500; value.family = .mono; value.alignment = .leading; value.lineHeight = 1.4
            value.x = 0.12; value.y = 0.5; value.maxWidth = 0.76
            value.enterKind = .type; value.enterDuration = 1.20; value.exitKind = .none; value.exitDuration = 0
        }
        return value
    }

    /// 与某段文字最接近的预设（面板里高亮那一格）；差得太远返回 nil。
    /// 把预设套到一段已有文字上。
    ///
    /// **反过来写**：这里列举的是"预设要改哪些"，而不是"要保留哪些"。
    /// 后者每给文字加一个新参数就会漏一次，而且漏了完全不报错，只表现为
    /// "点一下预设，刚调好的分屏占比被打回默认"——版式那几项已经这样漏过一次。
    /// 反着写的话，新加的参数默认就是保留，忘了登记最多是"预设管不到它"，无害得多。
    public func applied(to value: TextSegment) -> TextSegment {
        let sample = segment(start: value.start, duration: value.duration)
        var result = value
        result.preset = sample.preset
        result.size = sample.size; result.weight = sample.weight; result.family = sample.family
        result.alignment = sample.alignment
        result.lineHeight = sample.lineHeight; result.tracking = sample.tracking
        result.x = sample.x; result.y = sample.y; result.maxWidth = sample.maxWidth
        result.color = sample.color; result.opacity = sample.opacity
        result.plate = sample.plate; result.plateColor = sample.plateColor; result.plateOpacity = sample.plateOpacity
        result.platePadding = sample.platePadding; result.plateRadius = sample.plateRadius
        result.shadow = sample.shadow; result.shadowOpacity = sample.shadowOpacity
        result.shadowBlur = sample.shadowBlur; result.shadowOffset = sample.shadowOffset
        result.enterKind = sample.enterKind; result.enterDuration = sample.enterDuration
        result.exitKind = sample.exitKind; result.exitDuration = sample.exitDuration
        return result
    }

    public static func matching(_ value: TextSegment) -> TextPreset? {
        allCases.first { preset in
            let reference = preset.segment(start: value.start, duration: value.duration)
            return abs(reference.size - value.size) < 0.5 && reference.weight == value.weight
                && reference.family == value.family && reference.alignment == value.alignment
                && abs(reference.x - value.x) < 0.005 && abs(reference.y - value.y) < 0.005
        }
    }
}

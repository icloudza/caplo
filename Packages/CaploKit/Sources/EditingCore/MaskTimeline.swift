import Foundation
import CoreGraphics

/// 区域遮罩：盖住画面里不该露出的内容（密钥、邮箱、聊天记录），或反过来把一块之外压暗做聚光灯。
///
/// 三条贯穿整个类型的设计：
/// 1. **坐标贴在录屏内容上**（内容归一化坐标，左上原点），聚焦推近时遮罩跟着内容一起被推近，
///    绝不会因为镜头移动而露出被挡的东西。
/// 2. **时间存在源素材域**，渲染时按剪辑表投影（`maskSpans`）。剪一刀，一条遮罩自己裂成两段；
///    把中间删掉，它自己合拢。关键帧的时间同样记在源素材上，剪辑之后也不跑偏。
/// 3. **失败一侧一律 fail-closed**：解不出来的强度按最强像素化处理，绝不退化成"不打码"。
public struct MaskSegment: Codable, Equatable, Sendable, Identifiable {
    /// `sensitive` 盖住内容（模糊 / 像素化，不透明度恒为 1）；`highlight` 只压暗区域之外。
    public enum Kind: String, Codable, CaseIterable, Sendable { case sensitive, highlight }
    /// 遮住内容的手段。存进文件的是 `pixelation` 的编码值，这个枚举只在内存里用。
    public enum Effect: String, Codable, CaseIterable, Sendable { case blur, pixelate }
    public enum Shape: String, Codable, CaseIterable, Sendable { case rectangle, ellipse }

    public var id = UUID()
    /// 源素材时间起点与时长。`timelineStart` 非空表示用户把它固定到了成片时间，不再跟随剪辑。
    public var start: Double
    public var duration: Double
    public var timelineStart: Double?
    public var kind: Kind = .sensitive
    public var shape: Shape = .rectangle
    /// 中心与尺寸，内容归一化坐标（左上原点）。
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// 强度的编码值：`>= 1000` 表示模糊、强度为值减一千；否则表示像素化、强度即为值。
    /// 旧版本读到这个超大值会当成强像素化，仍然挡得住，不会变成"没打码"。
    public var pixelation: Double = MaskSegment.defaultAmount
    /// 边缘羽化，单位与强度一致（1080 参考像素）。敏感遮罩默认 0，形状边界清晰。
    public var feather: Double = 0
    public var cornerRadius: Double = 0
    /// 高亮类型：区域之外压暗多少。
    public var darkness: Double = 0.55
    /// 只有高亮类型有淡入淡出。敏感遮罩硬切，见 `alpha(at:)` 的注释。
    public var fadeIn: Double?
    public var fadeOut: Double?
    public var enabled = true
    public var title: String?
    /// 三条关键帧轨，时间相对遮罩自身的源起点。
    public var positionKeys: [MaskPointKeyframe]?
    public var sizeKeys: [MaskPointKeyframe]?
    public var amountKeys: [MaskValueKeyframe]?

    // MARK: 常量

    /// 强度取值范围（1080 参考像素）。低于 8 的敏感遮罩很可能仍然认得出内容，面板会警告。
    public static let amountRange: ClosedRange<Double> = 4...80
    public static let defaultAmount: Double = 16
    /// 强度低于这个值时提示"可能仍然认得出来"。
    public static let weakAmount: Double = 8
    /// 模糊在文件里的编码偏移。
    public static let blurEncodingOffset: Double = 1000
    /// 敏感遮罩两端各多生效这么久。转场那一两帧最容易漏出原文，用余量换掉淡入淡出。
    public static let safetyPad: Double = 0.10

    public init(start: Double, duration: Double, x: Double, y: Double, width: Double, height: Double,
                kind: Kind = .sensitive, effect: Effect = .blur, amount: Double = MaskSegment.defaultAmount) {
        self.start = start; self.duration = duration
        self.x = x; self.y = y; self.width = width; self.height = height
        self.kind = kind
        self.pixelation = Self.encode(effect: effect, amount: amount)
        if kind == .highlight { fadeIn = 0.15; fadeOut = 0.15; feather = 0 }
    }

    // MARK: 编解码
    //
    // 手写解码：合成的解码器不认属性默认值，以后每加一个新参数，之前存下的工程就少一个键、
    // 整份作废（用户看到的是一句"编辑数据版本不支持或内容无效"）。除了位置尺寸与起止一律给默认值。
    private enum CodingKeys: String, CodingKey {
        case id, start, duration, timelineStart, kind, shape, x, y, width, height
        case pixelation, feather, cornerRadius, darkness, fadeIn, fadeOut, enabled, title
        case positionKeys, sizeKeys, amountKeys
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try box.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        start = try box.decode(Double.self, forKey: .start)
        duration = try box.decode(Double.self, forKey: .duration)
        x = try box.decode(Double.self, forKey: .x)
        y = try box.decode(Double.self, forKey: .y)
        width = try box.decode(Double.self, forKey: .width)
        height = try box.decode(Double.self, forKey: .height)
        id = try value(.id, UUID())
        timelineStart = try box.decodeIfPresent(Double.self, forKey: .timelineStart)
        kind = try value(.kind, Kind.sensitive)
        shape = try value(.shape, Shape.rectangle)
        // 强度缺失时按最强像素化兜底，与 decode(_:) 的 fail-closed 口径一致：绝不退化成"不打码"。
        pixelation = try value(.pixelation, Self.encode(effect: .pixelate, amount: Self.amountRange.upperBound))
        feather = try value(.feather, 0)
        cornerRadius = try value(.cornerRadius, 0)
        darkness = try value(.darkness, 0.55)
        fadeIn = try box.decodeIfPresent(Double.self, forKey: .fadeIn)
        fadeOut = try box.decodeIfPresent(Double.self, forKey: .fadeOut)
        enabled = try value(.enabled, true)
        title = try box.decodeIfPresent(String.self, forKey: .title)
        positionKeys = try box.decodeIfPresent([MaskPointKeyframe].self, forKey: .positionKeys)
        sizeKeys = try box.decodeIfPresent([MaskPointKeyframe].self, forKey: .sizeKeys)
        amountKeys = try box.decodeIfPresent([MaskValueKeyframe].self, forKey: .amountKeys)
    }

    // MARK: 强度编解码

    public static func encode(effect: Effect, amount: Double) -> Double {
        let clamped = min(amountRange.upperBound, max(amountRange.lowerBound, amount))
        return effect == .blur ? blurEncodingOffset + clamped : clamped
    }
    /// 解码永远给得出一个能挡住内容的结果：非有限值、负数、超出范围一律回落到最强像素化。
    public static func decode(_ raw: Double) -> (effect: Effect, amount: Double) {
        guard raw.isFinite, raw > 0 else { return (.pixelate, amountRange.upperBound) }
        if raw >= blurEncodingOffset {
            let amount = raw - blurEncodingOffset
            guard amount.isFinite, amountRange.contains(amount) else { return (.pixelate, amountRange.upperBound) }
            return (.blur, amount)
        }
        guard amountRange.contains(raw) else { return (.pixelate, amountRange.upperBound) }
        return (.pixelate, raw)
    }
    public var effect: Effect { Self.decode(pixelation).effect }
    public var amount: Double { Self.decode(pixelation).amount }
    public mutating func setEffect(_ effect: Effect) { pixelation = Self.encode(effect: effect, amount: amount) }
    public mutating func setAmount(_ value: Double) { pixelation = Self.encode(effect: effect, amount: value) }

    /// 敏感遮罩两端各多盖 0.10 秒；高亮不需要。
    public var safetyPad: Double { kind == .sensitive ? Self.safetyPad : 0 }
    public var displayTitle: String { title ?? defaultTitle(number: nil) }
    public func defaultTitle(number: Int?) -> String {
        let name = kind == .highlight ? "高亮" : (effect == .blur ? "模糊" : "像素化")
        return number.map { "\(name) \(String(format: "%02d", $0))" } ?? name
    }

    // MARK: 校验

    var isValid: Bool {
        guard start.isFinite, start >= 0, duration.isFinite, duration > 0,
              x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              (0...1).contains(x), (0...1).contains(y),
              width > 0.001, width <= 2, height > 0.001, height <= 2,
              pixelation.isFinite, pixelation >= 0, pixelation <= Self.blurEncodingOffset + Self.amountRange.upperBound,
              feather.isFinite, (0...200).contains(feather),
              cornerRadius.isFinite, (0...200).contains(cornerRadius),
              darkness.isFinite, (0...1).contains(darkness),
              (timelineStart.map { $0.isFinite && $0 >= 0 } ?? true),
              (fadeIn.map { $0.isFinite && (0...5).contains($0) } ?? true),
              (fadeOut.map { $0.isFinite && (0...5).contains($0) } ?? true) else { return false }
        for track in [positionKeys, sizeKeys].compactMap({ $0 }) {
            guard track.count <= 2000 else { return false }
            var previous = -1.0
            for key in track {
                guard key.time.isFinite, key.time >= -0.001, key.time <= duration + 0.001, key.time >= previous,
                      key.x.isFinite, key.y.isFinite else { return false }
                previous = key.time
            }
        }
        if let amountKeys {
            guard amountKeys.count <= 2000 else { return false }
            var previous = -1.0
            for key in amountKeys {
                guard key.time.isFinite, key.time >= -0.001, key.time <= duration + 0.001, key.time >= previous,
                      key.value.isFinite, key.value >= 0 else { return false }
                previous = key.time
            }
        }
        return true
    }
}

/// 位置 / 尺寸关键帧：时间相对遮罩自身的源起点，两个分量一起插值。
public struct MaskPointKeyframe: Codable, Equatable, Sendable {
    public var time: Double
    public var x: Double
    public var y: Double
    public init(time: Double, x: Double, y: Double) { self.time = time; self.x = x; self.y = y }
}
/// 强度关键帧，值是编码后的 `pixelation`。
public struct MaskValueKeyframe: Codable, Equatable, Sendable {
    public var time: Double
    public var value: Double
    public init(time: Double, value: Double) { self.time = time; self.value = value }
}

/// 一条遮罩在成片时间轴上的一段。一条遮罩可能被剪辑切成多段，所以不要假设一一对应。
public struct MaskSpan: Sendable, Hashable {
    public let maskID: UUID
    public let clipID: UUID?
    public let start: Double
    public let duration: Double
    /// 这一段的起点对应遮罩自身的第几秒（源时间偏移）。关键帧插值要用它，否则剪辑后关键帧会错位。
    public let offset: Double
    /// 这一段画的是"保持末帧"的定格：源时间不往前走，取值一律停在 `offset` 那一刻。
    public var frozen = false
    public var end: Double { start + duration }
}

/// 某一时刻遮罩的几何与强度，已经解码、已经插值。
public struct MaskState: Equatable, Sendable {
    public var kind: MaskSegment.Kind
    public var shape: MaskSegment.Shape
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var effect: MaskSegment.Effect
    /// 1080 参考像素下的强度。
    public var amount: Double
    public var feather: Double
    public var cornerRadius: Double
    public var darkness: Double
    /// 生效强度。敏感遮罩恒为 1。
    public var alpha: Double
}

extension VideoEdit {
    /// 遮罩列表的非可选视图。写入后重算版本号（见 `normalizeSchemaVersion`），
    /// 免得一个不含遮罩的工程被打上旧版本打不开的标记。
    public var maskList: [MaskSegment] {
        get { masks ?? [] }
        set { masks = newValue.isEmpty ? nil : newValue; normalizeSchemaVersion() }
    }

    public mutating func addMask(_ mask: MaskSegment) { maskList.append(mask) }

    /// 在成片的某一时刻新建遮罩。时间换算回源素材域（这样它以后跟着剪辑走），
    /// 几何默认取画面正中一块 30 % × 16 % 的横条，正好盖住一行文字。返回新遮罩的 ID。
    @discardableResult
    public mutating func insertMask(at time: Double, duration wanted: Double = 2,
                                    kind: MaskSegment.Kind = .sensitive, sourceDuration: Double) -> UUID? {
        guard time.isFinite, sourceDuration.isFinite, sourceDuration > 0 else { return nil }
        // 播放头落在时间线的空白处（删掉中间一块、或把块整体挪开之后就会有空白）时映射不出源时间。
        // 这时绝不能把成片秒数当成源秒数用：那样建出来的遮罩会钉在一段和用户意图无关的素材上，
        // 甚至投影不出任何一段——列表里有它、画面上没有，用户却以为已经打上码了。
        guard let source = sourceTime(at: max(0, min(time, max(0, self.duration - 0.00001)))) else { return nil }
        let start = max(0, min(source, max(0, sourceDuration - 1.0 / 30)))
        let length = max(1.0 / 30, min(wanted, sourceDuration - start))
        var mask = MaskSegment(start: start, duration: length, x: 0.5, y: 0.5, width: 0.3, height: 0.16, kind: kind)
        if kind == .highlight { mask.width = 0.5; mask.height = 0.4 }
        // 与文字同理：停在定格卡段上建的遮罩钉在成片时间，不然它会在卡段和正片上各出现一次。
        if let hold = holdClip(atTimeline: max(0, min(time, max(0, duration - 0.00001)))) {
            let anchor = max(0, min(time, (hold.timelineStart ?? 0) + hold.duration - 1.0 / 30))
            mask.timelineStart = anchor
            mask.duration = max(1.0 / 30, min(mask.duration, duration - anchor))
        }
        addMask(mask)
        return mask.id
    }
    public mutating func removeMask(id: UUID) { maskList.removeAll { $0.id == id } }
    public mutating func updateMask(id: UUID, _ change: (inout MaskSegment) -> Void) {
        var list = maskList
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index]); maskList = list
    }
    public func mask(id: UUID) -> MaskSegment? { maskList.first { $0.id == id } }

    /// 遮罩编号：只有一条时不编号；多条按在时间线上首次出现的位置排序，从 1 起。
    public func maskNumbers(using spans: [MaskSpan]? = nil) -> [UUID: Int] {
        let list = maskList
        guard list.count > 1 else { return [:] }
        var firstStart: [UUID: Double] = [:]
        for span in spans ?? maskSpans() { firstStart[span.maskID] = min(firstStart[span.maskID] ?? .infinity, span.start) }
        let ordered = list.enumerated().sorted { a, b in
            let x = firstStart[a.element.id] ?? (a.element.timelineStart ?? a.element.start)
            let y = firstStart[b.element.id] ?? (b.element.timelineStart ?? b.element.start)
            return x == y ? a.offset < b.offset : x < y
        }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.element.id, $0.offset + 1) })
    }
    public func maskDisplayTitle(_ mask: MaskSegment, numbers: [UUID: Int]? = nil) -> String {
        mask.title ?? mask.defaultTitle(number: (numbers ?? maskNumbers())[mask.id])
    }

    /// 遮罩在成片时间轴上的可见段。形状与 `focusSpans` 一致，但有一处关键差别：
    /// "保持末帧"的那段画面上仍然印着密钥，照样要遮（聚焦相反，只在真有画面的区间生效）。
    /// 那一截由 `projectSource` 产出一条 `frozen` 段——**冻住而不是拉伸**，
    /// 否则几秒长的定格卡段会把源素材的好几秒在一张静止画面上演完，遮罩提前撤掉。
    public func maskSpans(in range: Range<Double>? = nil, using existingIndex: TimelineIndex? = nil) -> [MaskSpan] {
        let index = existingIndex ?? TimelineIndex(clips: orderedScreenClips)
        let visible = range ?? 0..<duration
        var result: [MaskSpan] = []
        for mask in maskList where mask.enabled {
            if let start = mask.timelineStart {
                if start < visible.upperBound && start + mask.duration > visible.lowerBound {
                    result.append(MaskSpan(maskID: mask.id, clipID: nil, start: start, duration: mask.duration, offset: 0))
                }
                continue
            }
            let low = mask.start, high = mask.start + mask.duration
            // 按真正可见的段投影：被上层片段盖住的素材不出画，它上面的遮罩也不该出现。
            for span in index.visibleSpans(in: visible) {
                let clip = index.clips[span.index]
                let base = index.boundaries[span.index]
                for piece in Self.projectSource(low: low, high: high, clip: clip, base: base,
                                                spanStart: span.start, spanEnd: span.end) {
                    guard piece.start < visible.upperBound, piece.start + piece.duration > visible.lowerBound else { continue }
                    result.append(MaskSpan(maskID: mask.id, clipID: clip.id, start: piece.start,
                                           duration: piece.duration, offset: piece.offset, frozen: piece.frozen))
                }
            }
        }
        return result
    }

    /// 求某一时刻某条遮罩的状态；不在生效区间返回 nil。渲染与导出共用这一条路径。
    public func maskState(_ mask: MaskSegment, at time: Double, spans: [MaskSpan]? = nil) -> MaskState? {
        guard mask.enabled else { return nil }
        let all = spans ?? maskSpans()
        let pad = mask.safetyPad
        guard let span = all.first(where: { $0.maskID == mask.id && time >= $0.start - pad && time < $0.end + pad }) else { return nil }
        // 关键帧时间轴是"相对遮罩自身源起点"，用 span.offset 修正后，剪辑怎么动都还钉在原始录像的那一帧上。
        let local = span.frozen ? span.offset : min(max(0, time - span.start), span.duration) + span.offset
        let center = Self.samplePoint(mask.positionKeys, at: local, fallback: (mask.x, mask.y))
        let size = Self.samplePoint(mask.sizeKeys, at: local, fallback: (mask.width, mask.height))
        let raw = Self.sampleValue(mask.amountKeys, at: local, fallback: mask.pixelation)
        let decoded = MaskSegment.decode(raw)
        return MaskState(kind: mask.kind, shape: mask.shape, x: center.0, y: center.1,
                         width: max(0.001, size.0), height: max(0.001, size.1),
                         effect: decoded.effect, amount: decoded.amount,
                         feather: mask.kind == .sensitive ? mask.feather : 0,
                         cornerRadius: mask.cornerRadius, darkness: mask.darkness,
                         alpha: Self.maskAlpha(mask, at: time, span: span))
    }

    /// 生效强度。敏感遮罩恒为 1：用不透明度做淡入淡出等于把原始内容按比例混回画面，
    /// 0.15 秒乘 30 帧就是四帧可读的密钥，逐帧截图能还原。改用两端各多盖 0.10 秒的余量。
    ///
    /// 高亮的淡入淡出按**遮罩自身的时间**算，不是按这一段的边界。
    /// 按段边界算的话，一条跨过剪辑口的高亮会在每个剪辑口先淡出再淡入——播放时闪一下，
    /// 而那一刀在成片上本来是接得严丝合缝的。文字层的进出场动画早就是这个口径。
    static func maskAlpha(_ mask: MaskSegment, at time: Double, span: MaskSpan) -> Double {
        guard mask.kind == .highlight else { return 1 }
        let inLength = max(0.0001, mask.fadeIn ?? 0.15), outLength = max(0.0001, mask.fadeOut ?? 0.15)
        let elapsed = span.frozen ? span.offset : min(max(0, time - span.start), span.duration) + span.offset
        let left = mask.duration - elapsed
        guard elapsed >= 0, left > 0 else { return 0 }
        return min(1, max(0, min(SceneEvaluator.smootherstep(elapsed / inLength), SceneEvaluator.smootherstep(left / outLength))))
    }

    static func samplePoint(_ track: [MaskPointKeyframe]?, at time: Double, fallback: (Double, Double)) -> (Double, Double) {
        guard let track, !track.isEmpty else { return fallback }
        if time <= track[0].time { return (track[0].x, track[0].y) }
        if let last = track.last, time >= last.time { return (last.x, last.y) }
        for index in 0..<(track.count - 1) {
            let a = track[index], b = track[index + 1]
            guard time >= a.time, time <= b.time else { continue }
            let t = (time - a.time) / max(0.000_001, b.time - a.time)
            return (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
        }
        return fallback
    }
    static func sampleValue(_ track: [MaskValueKeyframe]?, at time: Double, fallback: Double) -> Double {
        guard let track, !track.isEmpty else { return fallback }
        if time <= track[0].time { return track[0].value }
        if let last = track.last, time >= last.time { return last.value }
        for index in 0..<(track.count - 1) {
            let a = track[index], b = track[index + 1]
            guard time >= a.time, time <= b.time else { continue }
            let t = (time - a.time) / max(0.000_001, b.time - a.time)
            return a.value + (b.value - a.value) * t
        }
        return fallback
    }

    /// 原素材某一时刻生效的遮罩，不经剪辑投影。缩略图这类"直接取一帧原素材"的路径用它，
    /// 否则封面上会印着已经被遮住的密钥。固定到成片时间的遮罩没有源映射，按它保留的源起点保守判定。
    public func sourceMasks(atSource time: Double) -> [MaskState] {
        guard time.isFinite else { return [] }
        return maskList.compactMap { mask in
            guard mask.enabled else { return nil }
            let pad = mask.safetyPad
            guard time >= mask.start - pad, time < mask.start + mask.duration + pad else { return nil }
            let local = min(max(0, time - mask.start), mask.duration)
            let center = Self.samplePoint(mask.positionKeys, at: local, fallback: (mask.x, mask.y))
            let size = Self.samplePoint(mask.sizeKeys, at: local, fallback: (mask.width, mask.height))
            let decoded = MaskSegment.decode(Self.sampleValue(mask.amountKeys, at: local, fallback: mask.pixelation))
            return MaskState(kind: mask.kind, shape: mask.shape, x: center.0, y: center.1,
                             width: max(0.001, size.0), height: max(0.001, size.1),
                             effect: decoded.effect, amount: decoded.amount,
                             feather: mask.kind == .sensitive ? mask.feather : 0,
                             cornerRadius: mask.cornerRadius, darkness: mask.darkness, alpha: 1)
        }
    }

    /// 这一刻所有生效的遮罩，按数组顺序（后加的盖在上面）。
    public func activeMasks(at time: Double, spans: [MaskSpan]? = nil) -> [MaskState] {
        let all = spans ?? maskSpans()
        return maskList.compactMap { maskState($0, at: time, spans: all) }
    }

    /// 存在强度低于警戒线的敏感遮罩时为真；导出前要提醒。
    public var hasWeakMask: Bool {
        maskList.contains { $0.enabled && $0.kind == .sensitive && $0.amount < MaskSegment.weakAmount }
    }
}

/// 时间线上的拖动。与聚焦不同，遮罩**不会**因为拖动而被固定到成片时间：
/// 一旦固定，后续再裁剪素材它就不跟着内容走了，密钥会从遮罩边上滑出来。
/// 所以这里直接改遮罩自己的时间域（未固定的改源时间），成片时间与源时间同速推进，
/// 一次拖动在同一个片段内是精确的，跨过剪辑口时块会跟着剪辑表跳一下，符合所见即所得。
extension VideoEdit {
    public mutating func dragMask(id: UUID, edge: FocusDragEdge, delta: Double, sourceDuration: Double) {
        guard delta.isFinite, sourceDuration.isFinite, sourceDuration > 0 else { return }
        var list = maskList
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        var mask = list[index]
        let pinned = mask.timelineStart != nil
        let limit = pinned ? max(duration, mask.duration) : sourceDuration
        let start = mask.timelineStart ?? mask.start
        guard start.isFinite, mask.duration.isFinite, mask.duration > 0 else { return }
        let minimum = min(1.0 / 30, limit)
        switch edge {
        case .body:
            let moved = min(max(0, limit - mask.duration), max(0, start + delta))
            if pinned { mask.timelineStart = moved } else { mask.start = moved }
        case .leading:
            let end = start + mask.duration
            let next = min(end - minimum, max(0, start + delta))
            if pinned { mask.timelineStart = next } else { mask.start = next }
            mask.duration = end - next
            // 关键帧的时间相对遮罩起点，起点动了就要一起平移，否则动画整体错位。
            mask.shiftKeys(by: next - start)
        case .trailing:
            mask.duration = min(limit - start, max(minimum, mask.duration + delta))
        }
        list[index] = mask; maskList = list
    }
}

extension MaskSegment {
    /// 起点在时间轴上移动 `delta` 秒，但内部动画不变：三条关键帧轨的时间反向平移，
    /// 落到新起点之前的只保留最后一个作为新的初始状态。
    mutating func shiftKeys(by delta: Double) {
        guard delta != 0 else { return }
        positionKeys = Self.shift(positionKeys, by: delta, duration: duration) { $0.time } set: { $0.time = $1 }
        sizeKeys = Self.shift(sizeKeys, by: delta, duration: duration) { $0.time } set: { $0.time = $1 }
        amountKeys = Self.shift(amountKeys, by: delta, duration: duration) { $0.time } set: { $0.time = $1 }
        if let first = positionKeys?.first { x = first.x; y = first.y }
        if let first = sizeKeys?.first { width = first.x; height = first.y }
        if let first = amountKeys?.first { pixelation = first.value }
    }

    static func shift<Key>(_ track: [Key]?, by delta: Double, duration: Double,
                           get: (Key) -> Double, set: (inout Key, Double) -> Void) -> [Key]? {
        guard var keys = track, !keys.isEmpty else { return track }
        for index in keys.indices { set(&keys[index], get(keys[index]) - delta) }
        if let passed = keys.lastIndex(where: { get($0) < 0 }) {
            var initial = keys[passed]; set(&initial, 0)
            keys = [initial] + keys[(passed + 1)...]
        }
        keys = keys.filter { get($0) <= duration + 0.001 }
        return keys.isEmpty ? nil : keys
    }
}

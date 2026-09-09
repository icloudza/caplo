import Foundation
import CoreGraphics

/// 编辑时间线引用连续原始录制的时间范围；暂停已在录制拼接时去除，剪辑不会修改媒体文件。
public struct VideoClip: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    /// 显式起点表示独立图层；缺省兼容旧工程的连续拼接。
    public var timelineStart: Double?
    /// 可用源时长小于块时长时，视频保持末帧、声音留空，不隐式变速。
    public var mediaDuration: Double?
    public var playableDuration: Double { min(duration, mediaDuration ?? duration) }
    public var sourceStart: Double
    public var duration: Double
    /// 片段级增益，乘在全局音量之上；1 为不变。
    public var systemGain: Float = 1
    public var microphoneGain: Float = 1
    /// 这是一段"定格卡段"，冻结自哪条片段。
    /// 镜头是绑在片段 ID 上的（`FocusSegment.targetClipID`），定格片段的 ID 是新的，
    /// 不认这门亲就会在卡段里把镜头整个丢掉——1.8× 的推近在卡段两端各硬跳一次。
    public var holdSource: UUID?
    /// 本片段不绘制光标与点击效果。
    public var cursorHidden = false
    /// 用户自定义的块名称；为空时时间线按"录制画面 01"这类默认规则命名。
    public var title: String?

    public init(sourceStart: Double, duration: Double) { self.sourceStart = sourceStart; self.duration = duration }

    private enum CodingKeys: String, CodingKey { case id, sourceStart, duration, timelineStart, mediaDuration, systemGain, microphoneGain, cursorHidden, title, holdSource }

    /// 旧文件没有片段级字段，按默认值解码。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceStart = try container.decode(Double.self, forKey: .sourceStart)
        duration = try container.decode(Double.self, forKey: .duration)
        timelineStart = try container.decodeIfPresent(Double.self, forKey: .timelineStart)
        mediaDuration = try container.decodeIfPresent(Double.self, forKey: .mediaDuration)
        systemGain = try container.decodeIfPresent(Float.self, forKey: .systemGain) ?? 1
        microphoneGain = try container.decodeIfPresent(Float.self, forKey: .microphoneGain) ?? 1
        cursorHidden = try container.decodeIfPresent(Bool.self, forKey: .cursorHidden) ?? false
        title = try container.decodeIfPresent(String.self, forKey: .title)
        holdSource = try container.decodeIfPresent(UUID.self, forKey: .holdSource)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceStart, forKey: .sourceStart)
        try container.encode(duration, forKey: .duration)
        try container.encodeIfPresent(timelineStart, forKey: .timelineStart)
        try container.encodeIfPresent(mediaDuration, forKey: .mediaDuration)
        if systemGain != 1 { try container.encode(systemGain, forKey: .systemGain) }
        if microphoneGain != 1 { try container.encode(microphoneGain, forKey: .microphoneGain) }
        if cursorHidden { try container.encode(cursorHidden, forKey: .cursorHidden) }
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(holdSource, forKey: .holdSource)
    }

    public func gain(for track: AudioTrack) -> Float { track == .system ? systemGain : microphoneGain }
    public var hasCustomSettings: Bool { systemGain != 1 || microphoneGain != 1 || cursorHidden }
}

/// 名称对应内置光标包；未知或自定义光标回退标准箭头。
public enum PointerShape: String, Codable, CaseIterable, Sendable {
    case arrow, pointer, text, grab, grabbing, crosshair, resizeEW, resizeNS, resizeNESW, resizeNWSE, notAllowed, alias, copy, contextMenu
}

public struct PointerSample: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case move, click, exit, release, drag, scroll }
    public var time: Double
    public var x: Double
    public var y: Double
    public var kind: Kind
    public var cursorAssetID: String?
    public var shape: PointerShape?
    public var button: Int?
    public var clickCount: Int?
    public var scrollX: Double?
    public var scrollY: Double?
    public init(time: Double, x: Double, y: Double, kind: Kind) {
        self.time = time; self.x = x; self.y = y; self.kind = kind
    }
    // 录制时每个采样都带过一份桌面范围，但全仓没有任何一处读它——一场三十分钟的录制里
    // 那是几百万个白存的 CGRect。删掉之后旧工程照常解码（多余的键会被忽略），文件也小了。
    private enum CodingKeys: String, CodingKey { case time, x, y, kind, cursorAssetID, shape, button, clickCount, scrollX, scrollY }
}

/// 镜头内部的一处运动目标：从上一状态在 `time` 起用 `move` 秒过渡到本关键帧的位置与倍率，之后保持。
/// 时间相对镜头起点；第一帧通常在 0 且 `move` 为 0，表示推近时的初始相机。
public struct FocusKeyframe: Codable, Equatable, Sendable {
    public var time: Double
    public var x: Double
    public var y: Double
    public var scale: Double
    public var move: Double

    public init(time: Double, x: Double, y: Double, scale: Double, move: Double) {
        self.time = time; self.x = x; self.y = y; self.scale = scale; self.move = move
    }
}

/// 聚焦位置使用录制内容内的归一化坐标，左上角为原点；旧镜头跟随原素材，手动拖动可转为编辑时间。
/// `x` / `y` / `scale` 为初始相机；`path` 存在时相机按关键帧连续运动，`easeIn` / `easeOut` 为推近与拉远时长
/// （缺省为旧版 0.4 秒曲线）。时间线跟随在媒体或范围变化后重新规划；手动指定位置则回到固定相机。
public struct FocusSegment: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var start: Double
    public var duration: Double
    public var x: Double
    public var y: Double
    public var scale: Double
    public var automatic: Bool
    public var timelineStart: Double?
    public var targetClipID: UUID?
    /// 显式编辑时间内按实际可见素材的鼠标事件规划。可选字段兼容旧工程的固定 / 已烘焙路径。
    /// 跨片段后解除单素材关联，但仍由录制画面范围限制总时长；生成路径只存在于渲染副本。
    public var followsTimeline: Bool?
    public var transitionOffset: Double?
    public var transitionDuration: Double?
    public var path: [FocusKeyframe]?
    public var sampledPath: Bool?
    public var easeIn: Double?
    public var easeOut: Double?
    public enum Easing: String, Codable, CaseIterable, Sendable { case smooth, demo }
    public var easing: Easing?
    /// 用户自定义的块名称；为空时时间线显示"镜头聚焦 · 倍率"。
    public var title: String?
    /// 时间线块与属性面板共用的显示名：自定义名称优先，否则"镜头聚焦 · 1.8×"。
    /// 工程里有多个镜头时请用 `VideoEdit.focusDisplayTitle(_:)`，它会按时间线顺序编号成"镜头聚焦 2 · 1.8×"。
    public var displayTitle: String { title ?? defaultTitle(number: nil) }
    /// 默认名："镜头聚焦 · 1.8×"，给了序号则是"镜头聚焦 2 · 1.8×"。
    public func defaultTitle(number: Int?) -> String {
        number.map { String(format: "镜头聚焦 %d · %.1f×", $0, scale) } ?? String(format: "镜头聚焦 · %.1f×", scale)
    }
    public var editingStart: Double {
        get { timelineStart ?? start }
        set { if timelineStart != nil { timelineStart = newValue } else { start = newValue } }
    }
    public init(start: Double, duration: Double, x: Double, y: Double, scale: Double = 1.8, automatic: Bool = false) {
        self.start = start; self.duration = duration; self.x = x; self.y = y
        self.scale = scale; self.automatic = automatic
    }
}

public enum AudioTrack: String, Codable, CaseIterable, Sendable, Identifiable {
    case system, microphone
    public var id: Self { self }
}

/// 音量与静音独立保存；独奏可同时选多轨，静音优先于独奏。预览和导出共用最终增益规则。
public struct AudioLevels: Codable, Equatable, Sendable {
    public var system: Float = 0.7
    public var microphone: Float = 1
    public var muted: Set<AudioTrack> = []
    public var solo: Set<AudioTrack> = []
    /// 麦克风走离线语音处理产物（回声消除与降噪）；旧工程缺省关闭。
    public var voiceProcessing = false
    public init() {}
    public subscript(track: AudioTrack) -> Float {
        get { track == .system ? system : microphone }
        set { if track == .system { system = newValue } else { microphone = newValue } }
    }
    public func effectiveGain(for track: AudioTrack) -> Float {
        guard !muted.contains(track), solo.isEmpty || solo.contains(track) else { return 0 }
        let gain = self[track]
        return gain.isFinite ? min(1, max(0, gain)) : 0
    }
    private enum CodingKeys: String, CodingKey { case system, microphone, muted, solo, voiceProcessing }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        system = try values.decode(Float.self, forKey: .system)
        microphone = try values.decode(Float.self, forKey: .microphone)
        // 旧工程只保存两个音量值；新增开关缺失时保持原有可听结果，非法枚举仍拒绝载入。
        muted = try values.decodeIfPresent(Set<AudioTrack>.self, forKey: .muted) ?? []
        solo = try values.decodeIfPresent(Set<AudioTrack>.self, forKey: .solo) ?? []
        voiceProcessing = try values.decodeIfPresent(Bool.self, forKey: .voiceProcessing) ?? false
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(system, forKey: .system); try values.encode(microphone, forKey: .microphone)
        try values.encode(muted.sorted { $0.rawValue < $1.rawValue }, forKey: .muted)
        try values.encode(solo.sorted { $0.rawValue < $1.rawValue }, forKey: .solo)
        try values.encode(voiceProcessing, forKey: .voiceProcessing)
    }
}

public struct VideoEdit: Codable, Equatable, Sendable {
    /// 分割、裁剪、拖边都不允许把片段做得比这更短：太短的片段在时间线上只剩几个像素，既抓不住也没有意义。
    public static let minimumClipDuration = 0.25
    /// 工程文件版本。**不要直接写数字**，请调用 `normalizeSchemaVersion(layered:)`。
    /// 直接赋值曾经把另一处刚算好的版本冲掉，结果是"添加遮罩"直接报版本不支持。
    public var schemaVersion = 5
    /// 写出去的工程用这个版本号。5 是最初的连续拼接，6 是每个块都有显式起点的图层模型。
    /// 遮罩 / 文字层 / 字幕**不再各自升一档**：旧版本打开只会少画几层叠加内容，
    /// 不会显示错的画面，为此把工程标成"打不开"得不偿失。
    public static let writtenSchemaVersion = 6
    /// 还能打开的最高版本。开发期间存成 7 / 8 / 9 的工程照常打开，下次保存自动落回 6。
    public static let maximumSchemaVersion = 9
    public var clips: [VideoClip]
    public var layerOrder: [UUID]?
    /// 仅保存同行的成员关系；时间范围与合成优先级仍由片段数据、layerOrder 决定。
    public var rowGroups: [[UUID]]?
    public var cameraClips: [VideoClip]?
    public var systemClips: [VideoClip]?
    public var microphoneClips: [VideoClip]?
    public var layout = CanvasLayout()
    public var audio = AudioLevels()
    public var focuses: [FocusSegment] = []
    public var automaticFocus = true
    public var focusStyle: AutoFocusStyle?
    public var focusEngineVersion: Int?
    public var camera: CameraLayout?
    public var pointer: PointerEffects?
    /// 区域遮罩。旧工程没有这个键，所以是可选的；日常读写请用 `maskList`，它把空数组和缺省当成一回事。
    public var masks: [MaskSegment]?
    /// 文字层。同样是可选的，日常读写用 `textList`。
    public var texts: [TextSegment]?
    /// 字幕。可选，日常读写用 `captionList`。
    public var captions: [CaptionCue]?
    public var captionStyle: CaptionStyle?
    public init(duration: Double) { clips = duration > 0 ? [VideoClip(sourceStart: 0, duration: duration)] : [] }
    public var duration: Double {
        let mediaEnd = [clips, cameraClips ?? [], systemClips ?? [], microphoneClips ?? []].map { values in
            var cursor = 0.0, end = 0.0
            for clip in values { cursor = (clip.timelineStart ?? cursor) + clip.duration; end = max(end, cursor) }
            return end
        }.max() ?? 0
        // 效果仅改变录制画面，成片长度始终由媒体决定，不能产生只有聚焦的尾巴。
        return mediaEnd
    }
    public func timelineTime(forSource source: Double, in clipID: UUID? = nil) -> Double? {
        let index = TimelineIndex(clips: clips)
        let candidates = clipID.flatMap { id in clips.firstIndex { $0.id == id } }.map { [$0] } ?? Array(clips.indices)
        for number in candidates {
            let clip = clips[number]
            if source >= clip.sourceStart, source <= clip.sourceStart + clip.playableDuration {
                return index.boundaries[number] + min(clip.playableDuration - 0.00001, source - clip.sourceStart)
            }
        }
        return nil
    }
    public func clip(atTimeline time: Double) -> VideoClip? {
        let values = orderedScreenClips, index = TimelineIndex(clips: orderedScreenClips)
        guard time.isFinite, time >= 0, time <= index.duration else { return nil }
        return index.clipIndex(at: min(time, max(0, index.duration - 0.00001))).map { values[$0] }
    }
    public func sourceTime(at time: Double) -> Double? { TimelineIndex(clips: orderedScreenClips).sourceTime(at: time) }
    public func canSplit(at time: Double) -> Bool {
        let index = TimelineIndex(clips: clips)
        guard let number = index.clipIndex(at: time) else { return false }
        let offset = time - index.boundaries[number]
        return offset >= Self.minimumClipDuration && clips[number].duration - offset >= Self.minimumClipDuration
    }
    @discardableResult public mutating func split(at time: Double) -> Bool {
        let index = TimelineIndex(clips: clips)
        guard canSplit(at: time), let number = index.clipIndex(at: time) else { return false }
        splitMedia(.screen, id: clips[number].id, at: time)
        return true
    }

    public mutating func trim(id: UUID, leading: Double = 0, trailing: Double = 0) {
        guard leading.isFinite, trailing.isFinite, let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let head = min(max(0, leading), max(0, clips[index].duration - Self.minimumClipDuration))
        let tail = min(max(0, trailing), max(0, clips[index].duration - head - Self.minimumClipDuration))
        clips[index].sourceStart += head
        clips[index].duration -= head + tail
    }

    /// 调整源范围可重新展开已裁掉的内容；允许重用素材，始终约束在原录制内。
    public mutating func resize(id: UUID, sourceStart: Double, sourceEnd: Double, sourceDuration: Double) {
        guard sourceStart.isFinite, sourceEnd.isFinite, sourceDuration.isFinite, sourceDuration >= 1.0 / 30,
              let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let minimum = min(Self.minimumClipDuration, sourceDuration)
        let start = min(sourceDuration - minimum, max(0, sourceStart))
        let end = min(sourceDuration, max(start + minimum, sourceEnd))
        clips[index].sourceStart = start; clips[index].duration = end - start
    }

    /// 拒绝损坏或未知版本的编辑文件，避免自动保存覆盖无法理解的用户数据。
    public func validate(sourceDuration: Double) throws {
        let editedDuration = duration
        let focusCoverage = FocusCoverage(clips: clips)
        for media in [cameraClips, systemClips, microphoneClips].compactMap({ $0 }) {
            var isolated = VideoEdit(duration: 0); isolated.clips = media
            try isolated.validate(sourceDuration: sourceDuration)
        }
        guard (5...Self.maximumSchemaVersion).contains(schemaVersion),
              captionList.count <= 5000, Set(captionList.map(\.id)).count == captionList.count,
              captionStyle?.isValid != false,
              captionList.allSatisfy({ cue in cue.isValid && cue.sourceEnd <= sourceDuration + 0.001
                                       && (cue.timelineStart.map { $0 + cue.sourceDuration <= editedDuration + 0.001 } ?? true) }),
              textList.count <= 500, Set(textList.map(\.id)).count == textList.count,
              // 钉在成片时间上的叠加层只查成片域：它的 start 是源域的残留，没有任何一处读它。
              // 全屏卡段就靠这一条——在片尾附近插一段 3 秒卡段，源域上必然越界，
              // 按源域查等于整笔编辑回滚，用户只看到一句"内容无效"。
              textList.allSatisfy({ value in value.isValid && (value.timelineStart.map { $0 + value.duration <= editedDuration + 0.001 }
                                                               ?? (value.start + value.duration <= sourceDuration + 0.001)) }),
              maskList.count <= 500, Set(maskList.map(\.id)).count == maskList.count,
              maskList.allSatisfy({ mask in mask.isValid && (mask.timelineStart.map { $0 + mask.duration <= editedDuration + 0.001 }
                                                             ?? (mask.start + mask.duration <= sourceDuration + 0.001)) }),
              layerOrder.map({ Set($0).count == $0.count }) != false, focusStyle?.isValid != false, camera?.isValid != false, pointer?.isValid != false, clips.count <= 100_000, Set(clips.map(\.id)).count == clips.count,
              clips.allSatisfy({ $0.sourceStart.isFinite && $0.duration.isFinite && $0.sourceStart >= 0 && $0.duration >= 1.0 / 60 && $0.sourceStart + $0.playableDuration <= sourceDuration + 0.001
                                 && ($0.timelineStart.map { $0.isFinite && $0 >= 0 } ?? true) && ($0.mediaDuration.map { $0.isFinite && $0 > 0 } ?? true)
                                 && $0.systemGain.isFinite && (0...2).contains($0.systemGain) && $0.microphoneGain.isFinite && (0...2).contains($0.microphoneGain) }),
              layout.padding.isFinite, (0...120).contains(layout.padding), layout.cornerRadius.isFinite, (0...40).contains(layout.cornerRadius),
              layout.crop?.isValid != false, layout.backgroundImage.map({ $0.hasPrefix("Backgrounds/") && !$0.contains("..") }) != false,
              audio.system.isFinite, (0...1).contains(audio.system), audio.microphone.isFinite, (0...1).contains(audio.microphone),
              layout.shadowOpacity.isFinite, (0...1).contains(layout.shadowOpacity), layout.shadowBlur.isFinite, (0...60).contains(layout.shadowBlur),
              layout.shadowOffset.isFinite, (-40...40).contains(layout.shadowOffset),
              Set(focuses.map(\.id)).count == focuses.count,
              focuses.allSatisfy({ $0.validTiming(sourceDuration: sourceDuration, editedDuration: editedDuration) && focusCoverage.contains($0) && $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) && $0.scale.isFinite && (1...3).contains($0.scale) && $0.validMotion }) else {
            throw EditError.invalid
        }
    }
}

public enum EditError: LocalizedError {
    case invalid
    public var errorDescription: String? { "编辑数据版本不支持或内容无效，已保留原文件。" }
}

public struct FocusState: Equatable, Sendable {
    public var scale: Double = 1
    public var x: Double = 0.5
    public var y: Double = 0.5
    /// 推近程度 0…1（缓入缓出后的包络）；人像画中画按它同步缩小。目标倍数为 1 的镜头不算推近。
    public var envelope: Double = 0
    /// 未按倍数钳制的目标点（整体推近时以它为中心，越界由画布级钳制处理）。
    public var targetX: Double = 0.5
    public var targetY: Double = 0.5
    public init() {}
    init(scale: Double, x: Double, y: Double, envelope: Double, targetX: Double, targetY: Double) {
        self.scale = scale; self.x = x; self.y = y; self.envelope = envelope; self.targetX = targetX; self.targetY = targetY
    }
}

extension VideoEdit {
    /// 镜头编号：只有一个镜头时不编号；多个时按它们在时间线上首次出现的位置排序，从 1 起。
    /// 自动镜头关掉时不参与编号（它们也不显示）。
    public func focusNumbers() -> [UUID: Int] {
        let shown = focuses.filter { !$0.automatic || automaticFocus }
        guard shown.count > 1 else { return [:] }
        var firstStart: [UUID: Double] = [:]
        for span in focusSpans() { firstStart[span.focusID] = min(firstStart[span.focusID] ?? .infinity, span.start) }
        let ordered = shown.enumerated().sorted { a, b in
            let x = firstStart[a.element.id] ?? a.element.editingStart, y = firstStart[b.element.id] ?? b.element.editingStart
            return x == y ? a.offset < b.offset : x < y
        }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.element.id, $0.offset + 1) })
    }
    /// 镜头的默认名（含编号）。
    public func focusDefaultTitle(_ focus: FocusSegment, numbers: [UUID: Int]? = nil) -> String {
        focus.defaultTitle(number: (numbers ?? focusNumbers())[focus.id])
    }
    /// 时间线块与面板列表共用的显示名：自定义名优先，否则带编号的默认名。
    public func focusDisplayTitle(_ focus: FocusSegment, numbers: [UUID: Int]? = nil) -> String {
        focus.title ?? focusDefaultTitle(focus, numbers: numbers)
    }
}

/// 预览和导出只在此处求值镜头；剪辑后先映射回原素材，手动镜头优先于自动镜头。
/// 求值是无状态的：任意时刻都能独立算出相机，导出与拖动预览得到完全一致的画面。
///
/// 同一时刻可能有多个镜头生效（重叠、相邻衔接）：按"自动在下、手动在上，同类按层序"逐层混合，
/// 倍率从 1 起、位置从最底层镜头起逐层按各自包络 lerp，任何边界都没有跳变。
/// 相邻衔接：两个镜头间隔小于合并间隔时，前一个不拉远，保持推近直到后一个推近完成，视觉上直接平移过去。
public enum SceneEvaluator {
    /// 前一个镜头需要"保持推近"的额外秒数（越过自身时长），以及它衔接到的后一个镜头。
    public struct Link: Equatable, Sendable {
        public let hold: Double
        public let next: UUID
    }

    /// 相邻衔接关系：按时间域（时间线 / 原素材）分组，起点排序后看相邻两段的间隔。
    /// 分割出来的镜头片段（带 transition 字段）不参与衔接，它们的曲线本来就是一整段。
    public static func links(edit: VideoEdit) -> [UUID: Link] {
        let gap = edit.focusStyle?.isValid == true ? edit.focusStyle!.mergeGap : AutoFocusStyle().mergeGap
        guard gap > 0 else { return [:] }
        var result: [UUID: Link] = [:]
        for timelineBased in [false, true] {
            let group = edit.focuses.filter {
                (!$0.automatic || edit.automaticFocus) && ($0.timelineStart != nil) == timelineBased
                && $0.transitionOffset == nil && $0.transitionDuration == nil
            }.sorted { $0.editingStart < $1.editingStart }
            for (number, current) in group.enumerated() {
                let end = current.editingStart + current.duration
                guard let next = group.dropFirst(number + 1).first(where: { $0.editingStart >= end - 0.0001 }) else { continue }
                let distance = next.editingStart - end
                guard distance < gap, current.targetClipID == nil || next.targetClipID == nil || current.targetClipID == next.targetClipID else { continue }
                result[current.id] = Link(hold: distance + easeInLength(next), next: next.id)
            }
        }
        return result
    }

    /// 推近段长度：显式 easeIn 或旧镜头的 0.4 秒阶跃，都不超过时长的一半。
    static func easeInLength(_ zoom: FocusSegment) -> Double {
        let duration = zoom.transitionDuration ?? zoom.duration
        return max(0.001, min(zoom.easeIn ?? 0.4, duration / 2))
    }

    public static func focus(edit: VideoEdit, time: Double, timeline supplied: TimelineIndex? = nil, links suppliedLinks: [UUID: Link]? = nil) -> FocusState {
        let timeline = supplied ?? TimelineIndex(clips: edit.orderedScreenClips)
        guard let source = timeline.sourceTime(at: time) else { return FocusState() }
        let links = suppliedLinks ?? links(edit: edit)
        struct Layer { let zoom: FocusSegment; let elapsed: Double; let envelope: Double; let order: Int? }
        var layers: [Layer] = []
        // 定格片段认它冻结自的那条片段，镜头才不会在卡段里掉档。
        let visibleClip = timeline.clipIndex(at: time).map { timeline.clips[$0].holdSource ?? timeline.clips[$0].id }
        for zoom in edit.focuses where !zoom.automatic || edit.automaticFocus {
            if let target = zoom.targetClipID, target != visibleClip { continue }
            let visibleElapsed = (zoom.timelineStart == nil ? source : time) - zoom.editingStart
            let hold = links[zoom.id]?.hold ?? 0
            guard visibleElapsed >= 0, visibleElapsed < zoom.duration + hold else { continue }
            let elapsed = visibleElapsed + (zoom.transitionOffset ?? 0)
            let envelope = min(1, max(0, self.envelope(zoom, elapsed: elapsed, holding: hold > 0)))
            guard envelope > 0 else { continue }
            layers.append(Layer(zoom: zoom, elapsed: elapsed, envelope: envelope, order: edit.layerOrder?.firstIndex(of: zoom.id)))
        }
        guard !layers.isEmpty else { return FocusState() }
        // 层序（后应用的在上）：手动压过自动；衔接进来的镜头压过它接续的前一个；同类按层序（索引小在上），
        // 没有层序时后开始的在上（与原先"选一个镜头"的优先规则一致）。
        func above(_ a: Layer, _ b: Layer) -> Bool {
            if a.zoom.automatic != b.zoom.automatic { return !a.zoom.automatic }
            if links[b.zoom.id]?.next == a.zoom.id { return true }
            if links[a.zoom.id]?.next == b.zoom.id { return false }
            if let x = a.order, let y = b.order { return x < y }
            return a.elapsed < b.elapsed
        }
        layers.sort { above($1, $0) }
        var scale = 1.0, x = 0.5, y = 0.5, pushed = 0.0
        for (number, layer) in layers.enumerated() {
            let camera = layer.zoom.camera(at: layer.elapsed)
            scale += (camera.scale - scale) * layer.envelope
            if number == 0 { x = camera.x; y = camera.y } else { x += (camera.x - x) * layer.envelope; y += (camera.y - y) * layer.envelope }
            if camera.scale > 1.001 { pushed = max(pushed, layer.envelope) }
        }
        let margin = 0.5 / scale
        return FocusState(scale: scale, x: min(1 - margin, max(margin, x)), y: min(1 - margin, max(margin, y)), envelope: pushed, targetX: x, targetY: y)
    }

    /// 单个镜头此刻的包络；衔接出去的镜头（`holding`）只推近不拉远，保持到后一个镜头推近完成。
    static func envelope(_ zoom: FocusSegment, elapsed: Double, holding: Bool) -> Double {
        let curveDuration = zoom.transitionDuration ?? zoom.duration
        if zoom.easing == .demo {
            let inTime = max(0.001, min(zoom.easeIn ?? 0.6, curveDuration / 2))
            let outTime = max(0.001, min(zoom.easeOut ?? 0.7, curveDuration / 2))
            if elapsed < inTime { return DemoMotion.easeOut(elapsed / inTime) }
            if holding { return 1 }
            return elapsed > curveDuration - outTime ? 1 - DemoMotion.easeOut((elapsed - curveDuration + outTime) / outTime) : 1
        }
        if holding {
            guard let easeIn = zoom.easeIn else {
                let edge = min(0.4, curveDuration / 2), phase = min(1, elapsed / edge)
                return phase * phase * (3 - 2 * phase)
            }
            return smootherstep(elapsed / max(0.001, min(easeIn, curveDuration / 2)))
        }
        return envelope(elapsed: elapsed, duration: curveDuration, easeIn: zoom.easeIn, easeOut: zoom.easeOut)
    }

    /// 推近 / 拉远包络：旧镜头沿用 0.4 秒平滑阶跃；带显式时长的镜头用更平滑的五次曲线。
    static func envelope(elapsed: Double, duration: Double, easeIn: Double?, easeOut: Double?) -> Double {
        guard let easeIn, let easeOut else {
            let edge = min(0.4, duration / 2)
            let phase = min(1, min(elapsed / edge, (duration - elapsed) / edge))
            return phase * phase * (3 - 2 * phase)
        }
        let inLength = max(0.001, min(easeIn, duration / 2)), outLength = max(0.001, min(easeOut, duration / 2))
        let phase = max(0, min(1, min(elapsed / inLength, (duration - elapsed) / outLength)))
        return smootherstep(phase)
    }

    /// 首尾一二阶导数都为零的缓动，运动起止没有顿挫。
    static func smootherstep(_ t: Double) -> Double {
        let x = max(0, min(1, t))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
}

extension FocusSegment {
    /// 镜头内某一时刻的相机（位置与目标倍率，未含推近包络）。
    /// 关键帧之间用平滑缓动过渡；新过渡若在上一段未完成时开始，则从当时的中间状态出发，不会跳变。
    public func camera(at elapsed: Double) -> (x: Double, y: Double, scale: Double) {
        guard let path, let first = path.first else { return (x, y, scale) }
        if sampledPath == true {
            var low = 0, high = path.count
            while low < high {
                let middle = (low + high) / 2
                if path[middle].time <= elapsed { low = middle + 1 } else { high = middle }
            }
            let a = path[max(0, low - 1)], b = path[min(path.count - 1, low)]
            let t = max(0, min(1, (elapsed - a.time) / max(0.000001, b.time - a.time)))
            return (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.scale + (b.scale - a.scale) * t)
        }
        var from = (first.x, first.y, first.scale), to = from
        var startTime = first.time, move = 0.0
        for frame in path.dropFirst() where frame.time <= elapsed {
            let progress = SceneEvaluator.smootherstep(move > 0 ? (frame.time - startTime) / move : 1)
            from = (from.0 + (to.0 - from.0) * progress, from.1 + (to.1 - from.1) * progress, from.2 + (to.2 - from.2) * progress)
            to = (frame.x, frame.y, frame.scale)
            startTime = frame.time; move = frame.move
        }
        let progress = SceneEvaluator.smootherstep(move > 0 ? (elapsed - startTime) / move : 1)
        return (from.0 + (to.0 - from.0) * progress, from.1 + (to.1 - from.1) * progress, from.2 + (to.2 - from.2) * progress)
    }

    /// 关键帧路径与缓动时长必须有限、有序且在合法范围内。
    var validMotion: Bool {
        if let easeIn { guard easeIn.isFinite, (0...5).contains(easeIn) else { return false } }
        if let easeOut { guard easeOut.isFinite, (0...5).contains(easeOut) else { return false } }
        guard let path else { return true }
        guard !path.isEmpty, path.count <= (sampledPath == true ? 200_000 : 2000) else { return false }
        var previous = -1.0
        for frame in path {
            guard frame.time.isFinite, frame.time >= 0, frame.time <= (transitionDuration ?? duration) + 0.001, frame.time >= previous,
                  frame.move.isFinite, (0...10).contains(frame.move),
                  frame.x.isFinite, frame.y.isFinite, (0...1).contains(frame.x), (0...1).contains(frame.y),
                  frame.scale.isFinite, (1...3).contains(frame.scale) else { return false }
            previous = frame.time
        }
        return true
    }
}

/// 一次拖动只提交一次快照；有界历史避免长时间操作无限积累内存。
public struct EditHistory: Sendable {
    private var undoStack: [VideoEdit] = []
    private var redoStack: [VideoEdit] = []
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    /// 撤销栈的粗略"份量"上限。只按条数封顶不够：一份快照里可能钉着几千个采样运镜关键帧、
    /// 几百条字幕和上千个遮罩关键帧，一百份就能吃掉几百兆。这里按"关键点数"折算，够用且不用真去量字节。
    static let weightLimit = 400_000
    private var weights: [Int] = []
    private static func weight(_ edit: VideoEdit) -> Int {
        var value = edit.clips.count + edit.textList.count
        value += (edit.cameraClips?.count ?? 0) + (edit.systemClips?.count ?? 0) + (edit.microphoneClips?.count ?? 0)
        for cue in edit.captionList {
            value += 1 + (cue.words?.count ?? 0)
        }
        for mask in edit.maskList {
            value += 1 + (mask.positionKeys?.count ?? 0)
            value += (mask.sizeKeys?.count ?? 0) + (mask.amountKeys?.count ?? 0)
        }
        for focus in edit.focuses {
            value += 1 + (focus.path?.count ?? 0)
        }
        return max(1, value)
    }
    public init() {}
    public mutating func record(_ previous: VideoEdit) {
        undoStack.append(previous); weights.append(Self.weight(previous))
        // 条数与份量双上限：先按条数削，再按份量削，保证再大的工程也不会让撤销栈无限长胖。
        while undoStack.count > 100 || (weights.reduce(0, +) > Self.weightLimit && undoStack.count > 1) {
            undoStack.removeFirst(); weights.removeFirst()
        }
        redoStack.removeAll()
    }
    public mutating func undo(current: VideoEdit) -> VideoEdit? {
        guard let value = undoStack.popLast() else { return nil }
        if !weights.isEmpty { weights.removeLast() }
        redoStack.append(current); return value
    }
    public mutating func redo(current: VideoEdit) -> VideoEdit? {
        guard let value = redoStack.popLast() else { return nil }
        undoStack.append(current); weights.append(Self.weight(current)); return value
    }
}

extension VideoEdit {
    /// 归一化工程版本号，**这是唯一该写 `schemaVersion` 的地方**。
    ///
    /// 只有两个合法取值：5（最初的连续拼接）和 6（每个块有显式起点的图层模型）。
    /// 叠加层不再各自升一档——那样做的代价是旧版本直接报"版本不支持"，
    /// 收益只是"旧版本少画一层"这件本来就无害的事，不划算。
    /// 开发期间存成 7 / 8 / 9 的工程仍然读得进来，在这里落回 6。
    ///
    /// `layered` 为真表示这次操作把工程升到了图层模型。
    public mutating func normalizeSchemaVersion(layered: Bool = false) {
        schemaVersion = layered ? Self.writtenSchemaVersion : min(max(schemaVersion, 5), Self.writtenSchemaVersion)
    }
}

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
    /// 本片段不绘制光标与点击效果。
    public var cursorHidden = false
    /// 用户自定义的块名称；为空时时间线按"录制画面 01"这类默认规则命名。
    public var title: String?

    public init(sourceStart: Double, duration: Double) { self.sourceStart = sourceStart; self.duration = duration }

    private enum CodingKeys: String, CodingKey { case id, sourceStart, duration, timelineStart, mediaDuration, systemGain, microphoneGain, cursorHidden, title }

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
    public var desktopBounds: CGRect?
    public var cursorAssetID: String?
    public var shape: PointerShape?
    public var button: Int?
    public var clickCount: Int?
    public var scrollX: Double?
    public var scrollY: Double?
    public init(time: Double, x: Double, y: Double, kind: Kind, desktopBounds: CGRect? = nil) {
        self.time = time; self.x = x; self.y = y; self.kind = kind; self.desktopBounds = desktopBounds
    }
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
    public var displayTitle: String { title ?? String(format: "镜头聚焦 · %.1f×", scale) }
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
    public var schemaVersion = 5
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
        guard (schemaVersion == 5 || schemaVersion == 6), layerOrder.map({ Set($0).count == $0.count }) != false, focusStyle?.isValid != false, camera?.isValid != false, pointer?.isValid != false, clips.count <= 100_000, Set(clips.map(\.id)).count == clips.count,
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

/// 预览和导出只在此处求值镜头；剪辑后先映射回原素材，手动镜头优先于自动镜头。
/// 求值是无状态的：任意时刻都能独立算出相机，导出与拖动预览得到完全一致的画面。
public enum SceneEvaluator {
    public static func focus(edit: VideoEdit, time: Double, timeline supplied: TimelineIndex? = nil) -> FocusState {
        let timeline = supplied ?? TimelineIndex(clips: edit.orderedScreenClips)
        guard let source = timeline.sourceTime(at: time) else { return FocusState() }
        var selected: (FocusSegment, Double)?
        let visibleClip = timeline.clipIndex(at: time).map { timeline.clips[$0].id }
        for zoom in edit.focuses where !zoom.automatic || edit.automaticFocus {
            if let target = zoom.targetClipID, target != visibleClip { continue }
            let visibleElapsed = (zoom.timelineStart == nil ? source : time) - zoom.editingStart
            guard visibleElapsed >= 0, visibleElapsed < zoom.duration else { continue }
            let elapsed = visibleElapsed + (zoom.transitionOffset ?? 0)
            if let current = selected {
                if zoom.automatic && !current.0.automatic { continue }
                if zoom.automatic == current.0.automatic {
                    if let order = edit.layerOrder, let candidate = order.firstIndex(of: zoom.id), let active = order.firstIndex(of: current.0.id) {
                        if candidate > active { continue }
                    } else if elapsed >= current.1 { continue }
                }
            }
            selected = (zoom, elapsed)
        }
        guard let (zoom, elapsed) = selected else { return FocusState() }
        let curveDuration = zoom.transitionDuration ?? zoom.duration
        let envelope: Double
        if zoom.easing == .demo {
            let inTime = max(0.001, min(zoom.easeIn ?? 0.6, curveDuration / 2))
            let outTime = max(0.001, min(zoom.easeOut ?? 0.7, curveDuration / 2))
            envelope = elapsed < inTime ? DemoMotion.easeOut(elapsed / inTime)
                : elapsed > curveDuration - outTime ? 1 - DemoMotion.easeOut((elapsed - curveDuration + outTime) / outTime) : 1
        } else { envelope = Self.envelope(elapsed: elapsed, duration: curveDuration, easeIn: zoom.easeIn, easeOut: zoom.easeOut) }
        let camera = zoom.camera(at: elapsed)
        let scale = 1 + (camera.scale - 1) * envelope
        let margin = 0.5 / scale
        return FocusState(scale: scale, x: min(1 - margin, max(margin, camera.x)), y: min(1 - margin, max(margin, camera.y)),
                          envelope: camera.scale > 1.001 ? min(1, max(0, envelope)) : 0, targetX: camera.x, targetY: camera.y)
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
    public init() {}
    public mutating func record(_ previous: VideoEdit) {
        undoStack.append(previous); if undoStack.count > 100 { undoStack.removeFirst() }; redoStack.removeAll()
    }
    public mutating func undo(current: VideoEdit) -> VideoEdit? {
        guard let value = undoStack.popLast() else { return nil }; redoStack.append(current); return value
    }
    public mutating func redo(current: VideoEdit) -> VideoEdit? {
        guard let value = redoStack.popLast() else { return nil }; undoStack.append(current); return value
    }
}

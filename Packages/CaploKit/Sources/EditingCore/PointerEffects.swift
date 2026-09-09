import Foundation
import CoreGraphics
import Foundation

public struct PointerEffects: Codable, Equatable, Sendable {
    public enum Tint: String, CaseIterable, Codable, Sendable { case violet, blue, yellow }
    public enum Style: String, CaseIterable, Codable, Sendable { case captured, original, macos, tahoe, inverted, minimal }
    public enum ClickEffect: String, CaseIterable, Codable, Sendable { case ripple, spotlight, echo }
    public var cursorVisible: Bool = true
    public var cursorScale: Double = 1.0
    public var clicksVisible: Bool = true
    public var clickScale: Double = 1.0
    public var tint: Tint = .violet
    public var style: Style = .original
    public var smoothing: Double = 0.0
    public var bounce: Double = 0.0
    public var bounceSpeed: Double = 1.0
    public var sway: Double = 0.0
    public var motionBlur: Double = 0.0
    public var hideIdle: Bool = false
    public var loop: Bool = false
    public var clickEffect: ClickEffect = .ripple
    /// 静态旋转角度（度，顺时针为正）。
    public var angle: Double = 0
    /// 动态朝向（0…1）：光标按移动方向转向的程度，慢速减弱、静止回正。
    public var directionFollow: Double = 0
    /// 用户绘制的光标样式 id（如 "1-03"）；有值时箭头用它画，为空时按 `style` 主题画。只影响箭头形状。
    public var cursorStyle: String?
    public init() {}
    /// 新录制采用上游融合后的温和预设；旧文件解码仍保留原始外观。
    public static var recommended: PointerEffects {
        var value = PointerEffects()
        value.style = .tahoe; value.smoothing = 0.5; value.bounce = 0.2; value.motionBlur = 0.15
        return value
    }
    private enum CodingKeys: String, CodingKey { case cursorVisible, cursorScale, clicksVisible, clickScale, tint, style, smoothing, bounce, bounceSpeed, sway, motionBlur, hideIdle, loop, clickEffect, angle, directionFollow, cursorStyle }
    /// 缺失字段使用旧效果默认值，已有工程不会因升级突然改变外观。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 旧 shapeOverride 字段忽略：形状始终跟随录制，不保留隐藏的手动覆盖。
        // "显示光标"开关已去掉：光标始终显示，旧文件里存过 false 的也恢复显示（按片段隐藏仍在片段设置里）。
        _ = try c.decodeIfPresent(Bool.self, forKey: .cursorVisible)
        cursorVisible = true
        cursorScale = try c.decodeIfPresent(Double.self, forKey: .cursorScale) ?? 1.0
        clicksVisible = try c.decodeIfPresent(Bool.self, forKey: .clicksVisible) ?? true
        clickScale = try c.decodeIfPresent(Double.self, forKey: .clickScale) ?? 1.0
        tint = try c.decodeIfPresent(Tint.self, forKey: .tint) ?? .violet
        // 已删除的素材主题回退为现代主题；旧 assetOverride 字段由解码器忽略。
        if try c.decodeIfPresent(String.self, forKey: .style) == "recordly" { style = .tahoe }
        else { style = try c.decodeIfPresent(Style.self, forKey: .style) ?? .original }
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? 0.0
        bounce = try c.decodeIfPresent(Double.self, forKey: .bounce) ?? 0.0
        bounceSpeed = try c.decodeIfPresent(Double.self, forKey: .bounceSpeed) ?? 1.0
        sway = try c.decodeIfPresent(Double.self, forKey: .sway) ?? 0.0
        motionBlur = try c.decodeIfPresent(Double.self, forKey: .motionBlur) ?? 0.0
        hideIdle = try c.decodeIfPresent(Bool.self, forKey: .hideIdle) ?? false
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? false
        clickEffect = try c.decodeIfPresent(ClickEffect.self, forKey: .clickEffect) ?? .ripple
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
        directionFollow = try c.decodeIfPresent(Double.self, forKey: .directionFollow) ?? 0
        cursorStyle = try c.decodeIfPresent(String.self, forKey: .cursorStyle)
    }
    public var isValid: Bool {
        cursorScale.isFinite && (PointerEffects.minimumCursorScale...3).contains(cursorScale) && clickScale.isFinite && (0.5...2).contains(clickScale)
        && smoothing.isFinite && (0...2).contains(smoothing) && bounce.isFinite && (0...0.4).contains(bounce)
        && bounceSpeed.isFinite && (0.5...2).contains(bounceSpeed) && sway.isFinite && (0...1).contains(sway)
        && motionBlur.isFinite && (0...1).contains(motionBlur)
        && angle.isFinite && (-180...180).contains(angle) && directionFollow.isFinite && (0...1).contains(directionFollow)
    }
    /// 光标大小允许小于 1：下限是"系统光标大小"，按录制时真实光标的点尺寸换算，没有素材时按 0.5；这里是绝对下限。
    public static let minimumCursorScale = 0.2
    /// 主题光标 1.0× 时按 32 点画；真实光标的点高度除以它，就是与系统光标同大的倍率。
    public static let themeCursorPoints = 32.0
    /// 箭头光标尖端的默认朝向（屏幕坐标，y 向下）：指向左上；动态朝向就是把它转到移动方向。
    public static let arrowTipHeading = atan2(-0.9, -0.45)
}

public struct PointerFrame: Sendable {
    public struct Click: Sendable {
        public let position: CGPoint
        public let progress: Double
    }
    public var capturedCursor: CapturedCursor?
    public var position: CGPoint?
    public var clicks: [Click] = []
    public var previousShape: PointerShape?
    public var shapeMix = 1.0
    public var blurDelta = CGPoint.zero
    public var shape: PointerShape = .arrow
    public var scale = 1.0
    public var rotation = 0.0
    public var opacity = 1.0
    public var trail: [CGPoint] = []
    public init() {}
}

/// 事件只建立一次索引。播放时二分定位，最多评估最近 16 次点击，工作量不随录制时长增长。
public struct PointerTimeline: Sendable {
    private let capturedCursors: [String: CapturedCursor]
    private let events: [PointerSample]
    /// 去掉小幅反向抖动后的样本，只喂给平滑弹簧的目标；点击落点与真实位置仍用原始样本。
    private let motionEvents: [PointerSample]
    private let clicks: [PointerSample]
    private let appearance: PointerAppearance
    private let lastMotion: [Double]
    private let pathCache = PointerPathCache()
    public let cursorEmbedded: Bool
    /// 与光标共用已验证的录制事件；镜头规划只在编辑变更时读取，不重复解析事件文件。
    public var focusSamples: [PointerSample] { events }
    /// 与系统光标同大的倍率：录制时保存的箭头光标"可见部分"的点高度除以主题光标的 32 点；没有素材为 nil。
    /// 主题素材也是按可见范围裁过再按 32 点画的，两边口径一致；初始化时算一次（要解码一张 PNG）。
    public let systemCursorScale: Double?
    private static func systemCursorScale(events: [PointerSample], cursors: [String: CapturedCursor]) -> Double? {
        for event in events where event.shape == nil || event.shape == .arrow {
            guard let id = event.cursorAssetID, let cursor = cursors[id], let points = cursor.visibleHeightPoints, points > 0 else { continue }
            return min(1, max(PointerEffects.minimumCursorScale, points / PointerEffects.themeCursorPoints))
        }
        return nil
    }
    public init(events: [PointerSample], cursorEmbedded: Bool = true, capturedCursors: [String: CapturedCursor] = [:]) {
        self.capturedCursors = capturedCursors
        self.events = events.filter { $0.time.isFinite && $0.time >= 0 && $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }
            .sorted { $0.time < $1.time }
        self.clicks = self.events.filter { $0.kind == .click }
        self.motionEvents = Self.removingJitter(self.events)
        self.cursorEmbedded = cursorEmbedded
        self.systemCursorScale = Self.systemCursorScale(events: self.events, cursors: capturedCursors)
        self.appearance = PointerAppearance(events: self.events)
        var motion = 0.0
        var prior: PointerSample?
        self.lastMotion = self.events.map { sample in
            if prior == nil || sample.kind == .click || sample.kind == .drag || sample.kind == .scroll || sample.kind == .exit
                || hypot(sample.x - (prior?.x ?? sample.x), sample.y - (prior?.y ?? sample.y)) > 0.0002 { motion = sample.time }
            prior = sample
            return motion
        }
    }

    public func frame(at time: Double, timeline: TimelineIndex, effects: PointerEffects?) -> PointerFrame {
        var result = PointerFrame()
        guard let effects, time.isFinite, let source = timeline.sourceTime(at: time),
              let clipIndex = timeline.clipIndex(at: min(time, max(0, timeline.duration - 0.00001))) else { return result }
        let clipStart = timeline.clips[clipIndex].sourceStart
        let clipEnd = clipStart + timeline.clips[clipIndex].playableDuration
        let end = upperBound(source, in: clicks)
        if effects.clicksVisible {
            for index in max(0, end - 16)..<end {
                let click = clicks[index], elapsed = source - click.time
                if click.time >= clipStart, elapsed >= 0, elapsed < 0.55 {
                    result.clicks.append(PointerFrame.Click(position: CGPoint(x: click.x, y: click.y), progress: elapsed / 0.55))
                }
            }
        }
        guard effects.cursorVisible, !cursorEmbedded, let raw = rawPosition(at: source, clipStart: clipStart) else { return result }
        var position = smoothed(at: source, clipStart: clipStart, clipEnd: clipEnd, amount: effects.smoothing) ?? raw
        let previous = smoothed(at: max(clipStart, source - 1.0 / 60), clipStart: clipStart, clipEnd: clipEnd, amount: effects.smoothing) ?? position
        let dx = position.x - previous.x, dy = position.y - previous.y, distance = hypot(dx, dy)
        // 速度摆动公式；所有变换围绕热点，点击时尖端仍对准原像素。
        if distance > 0.000001 {
            result.rotation = min(1, max(-1, (dx + dy * 0.65) / distance)) * min(1, distance * 60 / 1.4) * .pi / 18 * effects.sway * 3
        }
        // 静态角度直接加；动态朝向按移动方向与箭头默认朝向的夹角旋转，慢速减弱、静止回正。
        result.rotation += effects.angle * .pi / 180
        if effects.directionFollow > 0, distance > 0.000001 {
            var delta = atan2(dy, dx) - PointerEffects.arrowTipHeading
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            result.rotation += delta * effects.directionFollow * min(1, distance * 60 / 0.5)
        }
        let eventIndex = upperBound(source, in: events) - 1
        if eventIndex >= 0 { result.shape = events[eventIndex].shape ?? .arrow }
        // 录制时保存的真实光标始终随帧给出：箭头以外的形状（手形、文字、抓取…）一律按真实光标画，样式只换箭头。
        if eventIndex >= 0, let id = events[eventIndex].cursorAssetID { result.capturedCursor = capturedCursors[id] }
        appearance.apply(to: &result, time: source, start: clipStart, end: clipEnd, effects: effects)
        // 原始位图已经包含具体形状，不与主题形状交叉混合。
        if effects.style == .captured { result.previousShape = nil; result.shapeMix = 1 }
        // 固定 1/60 秒源时间差生成方向模糊，播放帧率和随机寻址不会改变结果。
        result.blurDelta = CGPoint(x: dx, y: dy)
        // 循环只连接成片末尾到成片起点，不跨越任意剪辑边界补画轨迹。
        if effects.loop, timeline.duration >= 1, time > timeline.duration - 0.5,
           let first = timeline.sourceTime(at: 0), let target = rawPosition(at: first, clipStart: first) {
            let progress = SceneEvaluator.smootherstep((time - timeline.duration + 0.5) / 0.5)
            position.x += (target.x - position.x) * progress; position.y += (target.y - position.y) * progress
            result.opacity = 1; result.rotation *= 1 - progress
            result.blurDelta = .zero
        } else if effects.motionBlur > 0.05 {
            let count = max(1, Int((effects.motionBlur * 5).rounded()))
            for offset in 1...count {
                let past = source - Double(offset) / 120
                if past >= clipStart, let p = smoothed(at: past, clipStart: clipStart, clipEnd: clipEnd, amount: effects.smoothing), hypot(p.x - position.x, p.y - position.y) > 0.0001 { result.trail.append(p) }
            }
        }
        result.position = position
        return result
    }

    /// 抖动陷波：三点方向反转、两段位移都不到 0.015 且落在 100 毫秒窗内，就去掉中间那个点。
    /// 只针对"小幅来回"，不是低通，慢速直线移动一个点都不丢。
    static func removingJitter(_ samples: [PointerSample]) -> [PointerSample] {
        guard samples.count > 2 else { return samples }
        var result: [PointerSample] = [samples[0]]
        result.reserveCapacity(samples.count)
        for index in 1..<samples.count - 1 {
            let previous = result[result.count - 1], current = samples[index], next = samples[index + 1]
            let isMove = current.kind == .move && previous.kind == .move && next.kind == .move
            let ax = current.x - previous.x, ay = current.y - previous.y, bx = next.x - current.x, by = next.y - current.y
            let reversal = ax * bx + ay * by < 0
            if isMove, reversal, hypot(ax, ay) < 0.015, hypot(bx, by) < 0.015, next.time - previous.time <= 0.1 { continue }
            result.append(current)
        }
        result.append(samples[samples.count - 1])
        return result
    }

    private func rawPosition(at source: Double, clipStart: Double) -> CGPoint? { rawPosition(at: source, clipStart: clipStart, in: events) }
    private func rawPosition(at source: Double, clipStart: Double, in events: [PointerSample]) -> CGPoint? {
        let next = upperBound(source, in: events)
        guard next > 0 else { return nil }
        let previous = events[next - 1]
        guard previous.kind != .exit, source - previous.time <= 0.15 else { return nil }
        // 允许片段切入时读取切点之前的最近位置，但平滑器不读取已删除区间的运动历史。
        var p = CGPoint(x: previous.x, y: previous.y)
        if next < events.count {
            let following = events[next], interval = following.time - previous.time
            if following.kind != .exit, interval > 0, interval <= 0.15 {
                let weight = (source - previous.time) / interval
                p.x += (following.x - previous.x) * weight; p.y += (following.y - previous.y) * weight
            }
        }
        return p
    }

    /// 整条离线轨迹预计算：只生成一次，任意帧二分 / 索引读取。
    /// 每个剪辑从自己的源起点重置，缓存最多四条，避免每帧重新回看导致低速漂移和速度断续。
    private func smoothed(at source: Double, clipStart: Double, clipEnd: Double, amount: Double) -> CGPoint? {
        guard amount > 0 else { return rawPosition(at: source, clipStart: clipStart) }
        let end = min(clipEnd, (events.last?.time ?? clipStart) + 0.15)
        guard source <= end else { return nil }
        let key = PointerPathCache.Key(start: clipStart, end: end, smoothing: amount)
        let run = pathCache.run(key: key) {
            let rate = min(120.0, 1_000_000 / max(1, end - clipStart))
            let count = max(1, Int(ceil((end - clipStart) * rate)))
            var values: [CGPoint?] = []; values.reserveCapacity(count + 1)
            var x: PointerSpring?, y: PointerSpring?
            // 相位补偿：弹簧追动目标的稳态滞后 = 阻尼 / 刚度，让目标提前这么多采样，平滑后的光标压在真实位置上而不是拖在后面。
            let lag = PointerSpring.lag(smoothing: amount)
            for step in 0...count {
                let t = min(end, clipStart + Double(step) / rate)
                guard let p = rawPosition(at: t, clipStart: clipStart) else { values.append(nil); x = nil; y = nil; continue }
                let target = rawPosition(at: min(end, t + lag), clipStart: clipStart, in: motionEvents) ?? p
                if x == nil { x = PointerSpring(value: p.x); y = PointerSpring(value: p.y) }
                else { x?.step(target: target.x, dt: 1 / rate, smoothing: amount); y?.step(target: target.y, dt: 1 / rate, smoothing: amount) }
                var position = CGPoint(x: x!.value, y: y!.value)
                let index = upperBound(t, in: clicks)
                var weight = 0.0
                // 点击约束连续淡入淡出，替代硬 snap；尖端在点击瞬间严格落到记录位置。
                if index < clicks.count, clicks[index].time < end {
                    let distance = clicks[index].time - t
                    if distance < 0.2 { weight = SceneEvaluator.smootherstep(1 - distance / 0.2) }
                }
                if index > 0, clicks[index - 1].time >= clipStart {
                    let age = t - clicks[index - 1].time
                    if age < 0.2 { weight = max(weight, 1 - SceneEvaluator.smootherstep(age / 0.2)) }
                }
                position.x += (p.x - position.x) * weight; position.y += (p.y - position.y) * weight
                values.append(CGPoint(x: min(1, max(0, position.x)), y: min(1, max(0, position.y))))
            }
            return PointerPathCache.Run(rate: rate, values: values)
        }
        let coordinate = max(0, (source - clipStart) * run.rate)
        let index = min(run.values.count - 1, Int(coordinate))
        guard let a = run.values[index] else { return nil }
        guard index + 1 < run.values.count, let b = run.values[index + 1] else { return a }
        let t = coordinate - Double(index)
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private func upperBound(_ time: Double, in values: [PointerSample]) -> Int {
        var lower = 0, upper = values.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if values[middle].time <= time { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
}

/// 缓存只存不可变采样数组；锁覆盖首次构建和替换，多个导出工作线程不会重复生成同一轨迹。
private final class PointerPathCache: @unchecked Sendable {
    struct Key: Hashable { let start: Double; let end: Double; let smoothing: Double }
    struct Run { let rate: Double; let values: [CGPoint?] }
    private let lock = NSLock()
    private var entries: [Key: Run] = [:]
    private var order: [Key] = []
    func run(key: Key, build: () -> Run) -> Run {
        lock.lock(); defer { lock.unlock() }
        if let run = entries[key] { return run }
        let run = build()
        if order.count >= 4 { entries.removeValue(forKey: order.removeFirst()) }
        entries[key] = run; order.append(key)
        return run
    }
}

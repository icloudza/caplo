import Foundation
import CoreGraphics

/// 自动聚焦的风格参数；默认值按"跟手但不跟丢、少动多稳"的目标调过，单位为秒或归一化画面尺寸。
public struct AutoFocusStyle: Codable, Equatable, Sendable {
    /// 常规倍率与点击分散时的宽倍率。
    public var baseScale = 1.8
    public var wideScale = 1.45
    /// 比首次点击提前多久开始推近，让点击落在推近过程的后半段。
    public var leadTime = 0.35
    public var easeIn = 0.6
    public var easeOut = 0.7
    /// 最后一次点击之后多久拉远。
    public var idleTimeout = 2.2
    public var minimumDuration = 1.8
    /// 相邻两段间隔小于此值就合并，避免刚拉远又推近。
    public var mergeGap = 0.9
    /// 视口内不触发平移的中央区域占视口的比例，以及平移后把目标放回的更小区域比例。
    public var safeZone = 0.62
    public var innerZone = 0.42
    /// 光标离开安全区多久后才跟随；点击不受此延迟约束。
    public var followDelay = 0.3
    /// 判断点击分散度的时间窗。
    public var spreadWindow = 2.5

    public var prediction: Double?
    public var panResponse: Double?
    public var followsCursor = true
    public var demoEasing = false
    public var isValid: Bool {
        (prediction == nil || (prediction!.isFinite && (0...0.4).contains(prediction!)))
        && (panResponse == nil || (panResponse!.isFinite && (0.15...1.5).contains(panResponse!)))
        && [baseScale, wideScale].allSatisfy { $0.isFinite && (1...3).contains($0) }
        && [leadTime, easeIn, easeOut, idleTimeout, minimumDuration, mergeGap, followDelay, spreadWindow].allSatisfy { $0.isFinite && (0...10).contains($0) }
        && [safeZone, innerZone].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    public init() {}
}

/// 像相机导演一样规划镜头：以点击为主要线索决定何时推近、拉远，推近期间相机只做"刚好够"的平移，
/// 把目标带回视口中央区域；光标持续离开安全区时温和跟随；点击分散时自动放宽倍率。
/// 输出为带关键帧路径的 `FocusSegment`，所有运动由 `SceneEvaluator` 用连续曲线求值，不会跳变。
public enum AutoFocus {
    public static func generate(events: [PointerSample], duration: Double, style: AutoFocusStyle = AutoFocusStyle()) -> [FocusSegment] {
        guard style.isValid, duration.isFinite, duration > 0 else { return [] }
        let samples = events
            .filter { $0.time.isFinite && $0.time >= 0 && $0.time < duration && $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }
            .sorted { $0.time < $1.time }
        let clicks = samples.filter { $0.kind == .click }
        guard !clicks.isEmpty else { return [] }

        // 1. 按点击间隔分段：下一段若紧接着上一段的拉远，就并成一段。
        var groups: [[PointerSample]] = []
        for click in clicks {
            if let previous = groups.last?.last, click.time - previous.time < style.idleTimeout + style.leadTime + style.mergeGap {
                groups[groups.count - 1].append(click)
            } else {
                groups.append([click])
            }
        }

        var result: [FocusSegment] = []
        for group in groups {
            let start = max(0, group[0].time - style.leadTime)
            var end = min(duration, group[group.count - 1].time + style.idleTimeout)
            if end - start < style.minimumDuration { end = min(duration, start + style.minimumDuration) }
            guard end - start >= 0.5 else { continue }
            let path = self.path(clicks: group, samples: samples, start: start, end: end, style: style)
            var segment = FocusSegment(start: start, duration: end - start, x: path[0].x, y: path[0].y, scale: path[0].scale, automatic: true)
            segment.easing = style.demoEasing ? .demo : .smooth
            segment.easeIn = style.easeIn
            segment.easeOut = style.easeOut
            if style.followsCursor, path.count > 1 { segment.path = path; segment.sampledPath = true }
            result.append(segment)
        }
        return result
    }

    /// 将已有镜头切换为跟随模式：保留镜头时间和倍率，重建可编辑路径。
    /// 固定 / 跟随两种模式与参数组织；路径采用 Caplo 的边缘安全区策略。
    public static func following(_ segment: FocusSegment, events: [PointerSample], style: AutoFocusStyle) -> FocusSegment {
        guard style.isValid else { return segment }
        var result = segment, settings = style
        settings.baseScale = segment.scale; settings.wideScale = segment.scale
        let end = segment.start + segment.duration
        var clicks = events.filter { $0.kind == .click && $0.time >= segment.start && $0.time < end }
        if clicks.isEmpty { clicks = [PointerSample(time: segment.start, x: segment.x, y: segment.y, kind: .click)] }
        result.path = path(clicks: clicks, samples: events.filter { $0.x.isFinite && $0.y.isFinite && $0.time.isFinite }.sorted { $0.time < $1.time }, start: segment.start, end: end, style: settings)
        result.sampledPath = true
        return result
    }

    // MARK: 相机路径

    private static func path(clicks: [PointerSample], samples: [PointerSample], start: Double, end: Double, style: AutoFocusStyle) -> [FocusKeyframe] {
        let scale = scale(around: clicks[0].time, clicks: clicks, style: style)
        return SmartFollowPlanner.path(samples: samples, clicks: clicks, start: start, end: end, scale: scale, style: style)
    }

    /// 只把相机移动到刚好让目标回到内区的位置，并限制视口不出画面。
    static func retarget(_ center: CGPoint, toward point: CGPoint, scale: Double, zone: Double) -> CGPoint {
        let inner = 0.5 / scale * zone
        var next = center
        let dx = point.x - center.x, dy = point.y - center.y
        if abs(dx) > inner { next.x += dx - (dx > 0 ? inner : -inner) }
        if abs(dy) > inner { next.y += dy - (dy > 0 ? inner : -inner) }
        return clamp(next, scale: scale)
    }

    static func clamp(_ point: CGPoint, scale: Double) -> CGPoint {
        let margin = 0.5 / max(1, scale)
        return CGPoint(x: min(1 - margin, max(margin, point.x)), y: min(1 - margin, max(margin, point.y)))
    }

    /// 时间窗内点击的分散度决定倍率：连续在相距很远的位置点击时放宽视口，减少来回平移。
    private static func scale(around time: Double, clicks: [PointerSample], style: AutoFocusStyle) -> Double {
        let window = clicks.filter { $0.time >= time - style.spreadWindow && $0.time <= time + style.spreadWindow * 0.5 }
        guard window.count > 1, let minX = window.map(\.x).min(), let maxX = window.map(\.x).max(),
              let minY = window.map(\.y).min(), let maxY = window.map(\.y).max() else { return style.baseScale }
        let spread = hypot(maxX - minX, maxY - minY)
        if spread > 0.45 { return style.wideScale }
        if spread > 0.28 { return (style.baseScale + style.wideScale) / 2 }
        return style.baseScale
    }
}

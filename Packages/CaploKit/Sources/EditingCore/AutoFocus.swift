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
    /// 旧版安全区跟随的参数，2026-09-11 起不再参与规划；字段留着只为旧工程照常解码。
    public var safeZone = 0.62
    public var innerZone = 0.42
    public var followDelay = 0.3
    /// 判断点击分散度的时间窗。
    public var spreadWindow = 2.5

    /// 提前对准：每次换簇提前多少秒把目标换过去；nil 用弹簧的稳态滞后 2/ω₀（约 0.21 秒），0 就是 Cap 原样。
    public var prediction: Double?
    /// 跟随平滑度：换算成弹簧 ω₀ 的倍数，0.55 正好是 Cap 的默认弹簧；越大越慢越柔。
    public var panResponse: Double?
    /// 点击簇的宽度占视口的比例（面板上叫"安全区"），高度按 1.4 倍、不超过 0.95；nil 用 Cap 的 0.5。
    public var clusterWidth: Double?
    public var followsCursor = true
    public var demoEasing = false
    public var isValid: Bool {
        (prediction == nil || (prediction!.isFinite && (0...0.4).contains(prediction!)))
        && (panResponse == nil || (panResponse!.isFinite && (0.15...1.5).contains(panResponse!)))
        && (clusterWidth == nil || (clusterWidth!.isFinite && (0.2...0.9).contains(clusterWidth!)))
        && [baseScale, wideScale].allSatisfy { $0.isFinite && (1...3).contains($0) }
        && [leadTime, easeIn, easeOut, idleTimeout, minimumDuration, mergeGap, followDelay, spreadWindow].allSatisfy { $0.isFinite && (0...10).contains($0) }
        && [safeZone, innerZone].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    public init() {}
}

/// 像相机导演一样规划镜头：以点击为主要线索决定何时推近、拉远（提前 `leadTime`、停留 `idleTimeout`、间隔小就合并），
/// 点击分散时自动放宽倍率；推近期间相机往哪儿走由 `SmartFollowPlanner` 的点击簇 + 弹簧决定。
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
            let scale = scale(around: group[0].time, clicks: group, style: style)
            // 起手就对准首次点击那个簇：推近落点就是点击处，走向落点的路不算。
            let path = SmartFollowPlanner.path(samples: samples, start: start, end: end, scale: scale, style: style,
                                               aimAt: group[0].time, freezeTail: style.easeOut)
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
    public static func following(_ segment: FocusSegment, events: [PointerSample], style: AutoFocusStyle) -> FocusSegment {
        guard style.isValid else { return segment }
        var result = segment
        let end = segment.start + segment.duration
        let samples = events.filter { $0.x.isFinite && $0.y.isFinite && $0.time.isFinite }.sorted { $0.time < $1.time }
        let firstClick = samples.first { $0.kind == .click && $0.time >= segment.start && $0.time < end }
        result.path = SmartFollowPlanner.path(samples: samples, start: segment.start, end: end, scale: segment.scale, style: style,
                                              initial: firstClick == nil ? CGPoint(x: segment.x, y: segment.y) : nil,
                                              aimAt: firstClick?.time, freezeTail: style.easeOut)
        result.sampledPath = true
        return result
    }

    // MARK: 相机路径

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

import Foundation
import CoreGraphics

extension VideoEdit {
    /// 在构建播放项 / 导出任务时一次性预编译智能镜头；返回渲染副本，不改写用户保存的编辑数据。
    public func resolvingTimelineFocus(events: [PointerSample]) -> VideoEdit {
        guard focuses.contains(where: { $0.timelineStart != nil && $0.followsTimeline == true }) else { return self }
        let planner = TimelineFocusPlanner(edit: self, events: events)
        var result = self
        for index in result.focuses.indices where result.focuses[index].timelineStart != nil && result.focuses[index].followsTimeline == true {
            result.focuses[index] = planner.resolve(result.focuses[index])
        }
        return result
    }
}

/// 将真实可见素材分成源时间连续的规划段，硬切、空白与 exit 都阻断前瞻和惯性。
/// 时间较长但没有事件的区域只生成静态端点，不按 120Hz 遍历整段空白。
private struct TimelineFocusPlanner {
    private let timeline: TimelineIndex
    private let sourceLowerBySpan: [Double]
    private let samples: [PointerSample]
    private let style: AutoFocusStyle
    private static let epsilon = 0.000_000_1
    private static let maximumSamples = 500_000
    private static let maximumUnits = 16_000
    private static let maximumWindows = 16_000
    private static let maximumPath = 190_000
    private static let maximumSimulationSeconds = 1800.0

    private struct Run {
        var start: Double
        var end: Double
        let sourceStart: Double
        var sourceEnd: Double
        let sourceLower: Double
        let holding: Bool
    }
    private struct Window {
        let start: Double
        let end: Double
        let samples: Range<Int>
    }
    private struct Unit {
        enum Kind { case motion, fixed, hold }
        let start: Double
        let end: Double
        let kind: Kind
        let samples: [PointerSample]
        let windows: [Window]
        let reusePrevious: Bool
        let initial: PointerSample?
    }

    init(edit: VideoEdit, events: [PointerSample]) {
        let timeline = TimelineIndex(clips: edit.orderedScreenClips)
        self.timeline = timeline
        var contextStarts: [Double] = []
        var previousEnd = -1.0, previousSourceEnd = -1.0, previousWasLive = false
        for span in timeline.spans {
            let clip = timeline.clips[span.index], clipStart = timeline.boundaries[span.index]
            let sourceStart = clip.sourceStart + min(span.start - clipStart, clip.playableDuration)
            let sourceEnd = clip.sourceStart + min(span.end - clipStart, clip.playableDuration)
            let continuous = previousWasLive && abs(previousEnd - span.start) < Self.epsilon && abs(previousSourceEnd - sourceStart) < Self.epsilon
            contextStarts.append(continuous ? contextStarts.last ?? clip.sourceStart : clip.sourceStart)
            previousEnd = span.end; previousSourceEnd = sourceEnd
            previousWasLive = span.end <= clipStart + clip.playableDuration + Self.epsilon
        }
        sourceLowerBySpan = contextStarts
        style = edit.focusStyle?.isValid == true ? edit.focusStyle! : AutoFocusStyle()
        // 同时间事件保留录制顺序，重复规划不会因不稳定排序切换点击 / exit 的先后。
        let ordered = events.enumerated().compactMap { index, event -> (Int, PointerSample)? in
            guard event.time.isFinite, event.time >= 0 else { return nil }
            var sample = event
            if event.kind == .exit { sample.x = 0.5; sample.y = 0.5 }
            else { guard event.x.isFinite, event.y.isFinite, (0...1).contains(event.x), (0...1).contains(event.y) else { return nil } }
            return (index, sample)
        }.sorted { $0.1.time == $1.1.time ? $0.0 < $1.0 : $0.1.time < $1.1.time }.map(\.1)
        // 录制通常产生 60Hz 或更密的移动事件；先按 30Hz 确定性取最后位置，点击、松开和 exit 这些语义事件始终保留
        //（松开决定拖拽档位的区间，被抽稀掉拖拽就形同虚设）。
        func semantic(_ kind: PointerSample.Kind) -> Bool { kind == .click || kind == .exit || kind == .release }
        var reduced: [PointerSample] = []
        for sample in ordered {
            if !semantic(sample.kind), let previous = reduced.last, !semantic(previous.kind),
               floor(previous.time * 30) == floor(sample.time * 30) { reduced[reduced.count - 1] = sample }
            else { reduced.append(sample) }
        }
        let semanticCount = reduced.reduce(0) { $0 + (semantic($1.kind) ? 1 : 0) }
        let continuousBudget = max(1, 180_000 - semanticCount)
        let stride = max(1, Int(ceil(Double(reduced.count - semanticCount) / Double(continuousBudget))))
        if stride == 1 { samples = reduced }
        else {
            var ordinal = 0
            samples = reduced.enumerated().compactMap { index, sample in
                if semantic(sample.kind) { return sample }
                defer { ordinal += 1 }
                let boundary = index == 0 || index == reduced.count - 1 || semantic(reduced[index + 1].kind)
                return ordinal % stride == 0 || boundary ? sample : nil
            }
        }
    }

    func resolve(_ focus: FocusSegment) -> FocusSegment {
        guard let start = focus.timelineStart, start.isFinite, start >= 0, focus.duration.isFinite, focus.duration > 0,
              (start + focus.duration).isFinite, focus.scale.isFinite, (1...3).contains(focus.scale),
              focus.x.isFinite, focus.y.isFinite else { return focus }
        let offset = focus.transitionOffset ?? 0
        guard offset.isFinite, offset >= 0 else { return focus }
        let fallback = AutoFocus.clamp(CGPoint(x: focus.x, y: focus.y), scale: focus.scale)
        func staticResult() -> FocusSegment {
            var result = focus
            result.path = [FocusKeyframe(time: offset, x: fallback.x, y: fallback.y, scale: focus.scale, move: 0)]
            result.sampledPath = true
            return result
        }
        guard !samples.isEmpty else { return staticResult() }
        let end = start + focus.duration
        let runs = visibleRuns(start: start, end: end, target: focus.targetClipID)
        guard !runs.isEmpty, runs.count <= Self.maximumUnits else { return staticResult() }
        guard let units = units(for: runs, start: start, end: end) else { return staticResult() }
        let activeLength = units.reduce(0.0) { value, unit in value + unit.windows.reduce(0.0) { $0 + $1.end - $1.start } }
        // 极长且持续有动作的素材降低预编译采样密度；预测时长按比例缩放，绝不窥看更远的源事件。
        let timeScale = min(1, Self.maximumSimulationSeconds / max(1, activeLength))
        var output: [FocusKeyframe] = [], last = fallback
        func append(_ time: Double, _ position: CGPoint) {
            let frame = FocusKeyframe(time: max(offset, offset + time - start), x: position.x, y: position.y, scale: focus.scale, move: 0)
            if output.last == frame { return }
            output.append(frame)
        }
        for unit in units {
            switch unit.kind {
            case .fixed:
                append(unit.start, fallback); append(unit.end, fallback); last = fallback
            case .hold:
                let position = unit.reusePrevious ? last : unit.initial.map { AutoFocus.clamp(CGPoint(x: $0.x, y: $0.y), scale: focus.scale) } ?? fallback
                append(unit.start, position); append(unit.end, position); last = position
            case .motion:
                let lead = min(focus.easeIn ?? style.easeIn, focus.duration / 2) * 0.6
                var position = unit.reusePrevious ? last : initialPosition(samples: unit.samples, start: unit.start, fallback: fallback, scale: focus.scale, lead: lead)
                append(unit.start, position)
                var currentTime = unit.start
                for window in unit.windows {
                    if window.start > currentTime { append(window.start, position) }
                    let planned = plan(window, samples: unit.samples, initial: position, scale: focus.scale, timeScale: timeScale)
                    for frame in planned {
                        append(min(window.end, max(window.start, window.start + frame.time / timeScale)), CGPoint(x: frame.x, y: frame.y))
                    }
                    if let frame = planned.last { position = CGPoint(x: frame.x, y: frame.y) }
                    currentTime = window.end
                }
                append(unit.end, position); last = position
            }
            // 病态的十万次断源硬切无法在有限路径内忠实插值；安全回退固定镜头，不跨画面误追踪。
            if output.count > Self.maximumPath { return staticResult() }
        }
        var result = focus
        result.path = output.isEmpty ? staticResult().path : output
        result.sampledPath = true
        return result
    }

    private func visibleRuns(start: Double, end: Double, target: UUID?) -> [Run] {
        var lo = 0, hi = timeline.spans.count
        while lo < hi { let mid = (lo + hi) / 2; if timeline.spans[mid].end <= start { lo = mid + 1 } else { hi = mid } }
        var result: [Run] = []
        func append(_ run: Run) {
            guard run.end > run.start else { return }
            if let previous = result.last, previous.holding == run.holding,
               abs(previous.end - run.start) < Self.epsilon, abs(previous.sourceEnd - run.sourceStart) < Self.epsilon {
                result[result.count - 1].end = run.end; result[result.count - 1].sourceEnd = run.sourceEnd
            } else { result.append(run) }
        }
        for number in lo..<timeline.spans.count {
            let span = timeline.spans[number]
            guard span.start < end else { break }
            let clip = timeline.clips[span.index]
            // 定格片段冻结自哪条片段就跟着哪条走，与 SceneEvaluator.focus 同一口径。
            if let target, target != clip.id, target != clip.holdSource { continue }
            let lower = max(start, span.start), upper = min(end, span.end)
            guard upper > lower else { continue }
            let clipStart = timeline.boundaries[span.index], available = clip.playableDuration
            // 无绑定的镜头即使从连续切段之后才开始，也能读取同一连续录制的最近指针状态。
            // 关联限制决定镜头在哪个片段生效；连续源的历史位置仍可跨剪切继承，
            // 否则在后半段新建镜头时，静止鼠标会仅因更换片段 UUID 而丢失。
            let sourceLower = sourceLowerBySpan[number]
            let liveEnd = min(upper, clipStart + available)
            if liveEnd > lower {
                append(Run(start: lower, end: liveEnd, sourceStart: clip.sourceStart + lower - clipStart,
                           sourceEnd: clip.sourceStart + liveEnd - clipStart, sourceLower: sourceLower, holding: false))
            }
            if upper > liveEnd {
                let heldSource = clip.sourceStart + available
                append(Run(start: max(lower, liveEnd), end: upper, sourceStart: heldSource, sourceEnd: heldSource, sourceLower: sourceLower, holding: true))
            }
        }
        return result
    }

    private func units(for runs: [Run], start: Double, end: Double) -> [Unit]? {
        var result: [Unit] = [], cursor = start, mappedCount = 0, windowCount = 0
        var previous: Run?
        func appendZone(_ values: [PointerSample], start: Double, end: Double, resuming: Bool) {
            guard end > start else { return }
            let activity = activityWindows(values, start: start, end: end)
            windowCount += activity.count
            result.append(Unit(start: start, end: end, kind: values.isEmpty ? .fixed : .motion, samples: values, windows: activity, reusePrevious: resuming, initial: nil))
        }
        for run in runs {
            if run.start > cursor { result.append(Unit(start: cursor, end: run.start, kind: .fixed, samples: [], windows: [], reusePrevious: false, initial: nil)) }
            let context = precedingSample(for: run)
            if run.holding {
                let continuous = previous.map { abs($0.end - run.start) < Self.epsilon && abs($0.sourceEnd - run.sourceStart) < Self.epsilon } ?? false
                result.append(Unit(start: run.start, end: run.end, kind: .hold, samples: [], windows: [], reusePrevious: continuous, initial: context?.kind == .exit ? nil : context))
            } else {
                let first = lowerBound(run.sourceStart), last = lowerBound(run.sourceEnd)
                mappedCount += last - first
                guard mappedCount <= Self.maximumSamples else { return nil }
                var zoneStart = run.start, zone: [PointerSample] = []
                var outside = context?.kind == .exit, resuming = false, holdsPrevious = false
                if var context, context.kind != .exit {
                    // 片段中途开始的镜头可读取同素材最近位置，但历史点击只作为 move 状态，不能再次触发点击保持。
                    context.kind = .move; context.time = run.start; zone.append(context)
                }
                for index in first..<last {
                    var sample = samples[index]
                    sample.time = run.start + sample.time - run.sourceStart
                    if sample.kind == .exit {
                        if !outside {
                            appendZone(zone, start: zoneStart, end: sample.time, resuming: resuming)
                            holdsPrevious = sample.time > zoneStart
                            zone = []; zoneStart = sample.time; outside = true
                        }
                    } else {
                        if outside {
                            let waited = sample.time > zoneStart
                            if waited {
                                result.append(Unit(start: zoneStart, end: sample.time, kind: .hold, samples: [], windows: [], reusePrevious: holdsPrevious, initial: nil))
                            }
                            zoneStart = sample.time; outside = false; resuming = holdsPrevious || waited
                        }
                        zone.append(sample)
                    }
                    guard result.count <= Self.maximumUnits, windowCount <= Self.maximumWindows else { return nil }
                }
                if outside {
                    result.append(Unit(start: zoneStart, end: run.end, kind: .hold, samples: [], windows: [], reusePrevious: holdsPrevious, initial: nil))
                } else { appendZone(zone, start: zoneStart, end: run.end, resuming: resuming) }
            }
            cursor = run.end; previous = run
            guard result.count <= Self.maximumUnits, windowCount <= Self.maximumWindows else { return nil }
        }
        if cursor < end { result.append(Unit(start: cursor, end: end, kind: .fixed, samples: [], windows: [], reusePrevious: false, initial: nil)) }
        return result
    }

    private func precedingSample(for run: Run) -> PointerSample? {
        let index = lowerBound(run.sourceStart) - 1
        guard index >= 0, samples[index].time >= run.sourceLower else { return nil }
        return samples[index]
    }

    private func activityWindows(_ values: [PointerSample], start: Double, end: Double) -> [Window] {
        guard !values.isEmpty else { return [] }
        let prediction = min(0.4, max(0, style.prediction ?? 0.16))
        let settling = max(2, min(6, (style.panResponse ?? 0.55) * 6))
        var result: [Window] = [], first = 0
        for index in 1...values.count {
            if index == values.count || values[index].time - values[index - 1].time > settling + prediction {
                result.append(Window(start: max(start, values[first].time - prediction), end: min(end, values[index - 1].time + settling), samples: first..<index))
                first = index
            }
        }
        return result
    }

    /// 镜头起点的相机位置：0.4 秒内有点击就用点击；没有点击（手动讲解镜头）则做起点预判——
    /// 取推近完成六成时指针会在的位置（`lead` 秒后），推近落点就是指针所在，而不是按下那一刻的旧位置。
    private func initialPosition(samples: [PointerSample], start: Double, fallback: CGPoint, scale: Double, lead: Double) -> CGPoint {
        let nearby = samples.prefix { $0.time <= start + 0.4 }
        if let click = nearby.first(where: { $0.kind == .click }) { return AutoFocus.clamp(CGPoint(x: click.x, y: click.y), scale: scale) }
        if lead > 0, let ahead = PointerSpeedProbe(samples: samples).position(at: start + lead) { return AutoFocus.clamp(ahead, scale: scale) }
        guard let first = nearby.first else { return fallback }
        return AutoFocus.clamp(CGPoint(x: first.x, y: first.y), scale: scale)
    }

    private func plan(_ window: Window, samples: [PointerSample], initial: CGPoint, scale: Double, timeScale: Double) -> [FocusKeyframe] {
        let mapped = samples[window.samples].map { sample in
            var copy = sample; copy.time = (sample.time - window.start) * timeScale; return copy
        }
        if mapped.allSatisfy({ abs($0.x - initial.x) < 0.000_001 && abs($0.y - initial.y) < 0.000_001 }) {
            return [FocusKeyframe(time: 0, x: initial.x, y: initial.y, scale: scale, move: 0)]
        }
        // 初始化种子不产生虚假的点击保持；真正的未来点击只在其预测窗口内参与跟随。
        let seed = PointerSample(time: -1, x: initial.x, y: initial.y, kind: .click)
        let clicks = [seed] + mapped.filter { $0.kind == .click }
        var settings = style
        settings.prediction = (style.prediction ?? 0.16) * timeScale
        settings.panResponse = (style.panResponse ?? 0.55) * timeScale
        settings.easeOut = 0
        return SmartFollowPlanner.path(samples: mapped, clicks: clicks, start: 0, end: (window.end - window.start) * timeScale, scale: scale, style: settings)
    }

    private func lowerBound(_ time: Double) -> Int {
        var lo = 0, hi = samples.count
        while lo < hi { let mid = (lo + hi) / 2; if samples[mid].time < time { lo = mid + 1 } else { hi = mid } }
        return lo
    }
}

import Foundation
import CoreGraphics
import Testing
@testable import EditingCore

/// 点击簇 + 弹簧的跟随（2026-09-11 按 Cap 骨架重写）：响应滑块换算成弹簧刚度、邻近连点不换目标、墙面停住、
/// 起点预对准、纯函数可复现；以及光标平滑相位补偿、抖动陷波、短命形状去抖。
private func moves(from a: CGPoint, to b: CGPoint, start: Double, end: Double, rate: Double = 60) -> [PointerSample] {
    stride(from: start, through: end, by: 1 / rate).map { time in
        let progress = (time - start) / max(0.0001, end - start)
        return PointerSample(time: time, x: a.x + (b.x - a.x) * progress, y: a.y + (b.y - a.y) * progress, kind: .move)
    }
}
private func hold(_ p: CGPoint, start: Double, end: Double) -> [PointerSample] { moves(from: p, to: p, start: start, end: end) }
private func manualShot(start: Double, duration: Double, scale: Double = 1.8) -> FocusSegment {
    var shot = FocusSegment(start: start, duration: duration, x: 0.5, y: 0.5, scale: scale)
    shot.timelineStart = start; shot.followsTimeline = true; shot.easeIn = 0.6; shot.easeOut = 0.7
    return shot
}

@Test func responseSliderScalesTheSpringSoFasterSettlesSooner() {
    // 指针从 0.3 跳到 0.6（跳出盒子，换簇）：响应更快（ω 更大）的镜头更早到位；两者都到同一个终点，且从不越界。
    var edit = VideoEdit(duration: 10)
    edit.focuses = [manualShot(start: 0.5, duration: 9, scale: 2.0)]
    let events = hold(CGPoint(x: 0.3, y: 0.5), start: 0, end: 3) + hold(CGPoint(x: 0.6, y: 0.5), start: 3.02, end: 10)
    func resolved(response: Double) -> VideoEdit {
        var value = edit; var style = AutoFocusStyle(); style.panResponse = response; value.focusStyle = style
        return value.resolvingTimelineFocus(events: events)
    }
    func arrival(_ value: VideoEdit) -> Double {
        let target = value.focuses[0].camera(at: 8).x
        for time in stride(from: 2.0, through: 8.0, by: 1.0 / 240) where abs(SceneEvaluator.focus(edit: value, time: time).x - target) < 0.004 { return time }
        return .infinity
    }
    let quick = resolved(response: 0.3), slow = resolved(response: 1.2)
    #expect(abs(quick.focuses[0].camera(at: 8).x - slow.focuses[0].camera(at: 8).x) < 0.001)
    let quickArrival = arrival(quick), slowArrival = arrival(slow)
    #expect(quickArrival.isFinite && slowArrival.isFinite && quickArrival < slowArrival - 0.1)
    // 0.55 就是 Cap 的默认弹簧：ω₀ ≈ 9.43、ζ ≈ 0.94。
    var base = AutoFocusStyle(); base.panResponse = 0.55
    #expect(abs(SmartFollowPlanner.omega0(style: base) - 9.428) < 0.01 && abs(SmartFollowPlanner.capZeta - 0.9428) < 0.001)
}

@Test func nearbyRapidClicksNeverMoveTheCamera() {
    // 用户的原话：近距离快速点击相邻位置，聚焦切换频繁、过度跟随。一串点击都落在一个盒子里，相机目标一次都不换。
    var events: [PointerSample] = hold(CGPoint(x: 0.45, y: 0.5), start: 0, end: 1)
    let spots = [CGPoint(x: 0.52, y: 0.47), CGPoint(x: 0.48, y: 0.55), CGPoint(x: 0.55, y: 0.53), CGPoint(x: 0.5, y: 0.49), CGPoint(x: 0.53, y: 0.57)]
    var time = 1.0, at = CGPoint(x: 0.45, y: 0.5)
    for spot in spots {
        events.append(PointerSample(time: time, x: at.x, y: at.y, kind: .click))
        events.append(PointerSample(time: time + 0.02, x: at.x, y: at.y, kind: .release))
        events += moves(from: at, to: spot, start: time + 0.05, end: time + 0.3)
        at = spot; time += 0.35
    }
    events.append(PointerSample(time: time, x: at.x, y: at.y, kind: .click))
    events += hold(at, start: time + 0.02, end: time + 2.5)
    let shots = AutoFocus.generate(events: events, duration: time + 3)
    let shot = try! #require(shots.first)
    #expect(shots.count == 1)
    // 整段只有一个簇：路径退化成一帧，或者全程位移微乎其微。
    let path = shot.path ?? []
    let travel = zip(path, path.dropFirst()).reduce(0.0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    #expect(path.count <= 1 || travel < 0.01, "连点期间相机走了 \(travel)")
    var style = AutoFocusStyle()
    #expect(SmartFollowPlanner.clusters(samples: events, start: shot.start, end: shot.start + shot.duration, scale: shot.scale, style: style).count == 1)
    // 盒子按视口比例算：倍率越大盒子越小，同一串点击在 3 倍下就装不进一个盒子了。
    style.clusterWidth = 0.2
    #expect(SmartFollowPlanner.clusters(samples: events, start: shot.start, end: shot.start + shot.duration, scale: 3, style: style).count > 1)
}

@Test func passThroughClustersAreSkippedSoTheCameraGoesStraightToTheDestination() {
    // 指针 0.3 秒横穿整幅画面：途中的过路簇被并进终点簇，相机只换一次目标，且提前 2/ω 秒起步。
    var style = AutoFocusStyle()
    let events = hold(CGPoint(x: 0.15, y: 0.5), start: 0, end: 3) + moves(from: CGPoint(x: 0.15, y: 0.5), to: CGPoint(x: 0.85, y: 0.5), start: 3, end: 3.3) + hold(CGPoint(x: 0.85, y: 0.5), start: 3.3, end: 8)
    let clusters = SmartFollowPlanner.clusters(samples: events, start: 0, end: 8, scale: 2, style: style)
    // 指针跨出第一个盒子（一个盒子宽）那一刻就是换簇时刻，途中的小簇全并进终点簇。
    #expect(clusters.count == 2 && clusters[1].start > 3 && clusters[1].start < 3.2, "簇：\(clusters.map { ($0.start, $0.last) })")
    let departure = clusters[1].start
    let path = SmartFollowPlanner.path(samples: events, start: 0, end: 8, scale: 2, style: style)
    func x(at time: Double) -> Double {
        var low = 0, high = path.count
        while low < high { let m = (low + high) / 2; if path[m].time <= time { low = m + 1 } else { high = m } }
        let a = path[max(0, low - 1)], b = path[min(path.count - 1, low)]
        let t = max(0, min(1, (time - a.time) / max(0.000001, b.time - a.time)))
        return a.x + (b.x - a.x) * t
    }
    // 提前对准：换簇前 2/ω ≈ 0.21 秒相机已经起步；指针到达 0.4 秒后相机也基本到位。
    let base = x(at: 2.0)
    #expect(abs(x(at: departure - 0.3) - base) < 0.002 && x(at: departure - 0.05) > base + 0.01, "提前起步没发生：\(x(at: departure - 0.05)) vs \(base)")
    #expect(abs(x(at: 3.7) - 0.75) < 0.03, "到位太慢：\(x(at: 3.7))")
    // 提前对准拖到 0 就是 Cap 原样：换簇前相机纹丝不动。
    style.prediction = 0
    let plain = SmartFollowPlanner.path(samples: events, start: 0, end: 8, scale: 2, style: style)
    func plainX(at time: Double) -> Double {
        var low = 0, high = plain.count
        while low < high { let m = (low + high) / 2; if plain[m].time <= time { low = m + 1 } else { high = m } }
        let a = plain[max(0, low - 1)], b = plain[min(plain.count - 1, low)]
        return a.x + (b.x - a.x) * max(0, min(1, (time - a.time) / max(0.000001, b.time - a.time)))
    }
    #expect(abs(plainX(at: departure - 0.01) - plainX(at: 2.0)) < 0.002)
}

@Test func cameraStopsExactlyAtTheFrameEdgeWithoutOvershoot() {
    var edit = VideoEdit(duration: 10)
    edit.focuses = [manualShot(start: 0.5, duration: 9, scale: 2.0)]
    let events = hold(CGPoint(x: 0.5, y: 0.5), start: 0, end: 1) + moves(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.02, y: 0.03), start: 1, end: 1.4) + hold(CGPoint(x: 0.02, y: 0.03), start: 1.4, end: 10)
    let resolved = edit.resolvingTimelineFocus(events: events)
    let margin = 0.5 / 2.0
    var minX = 1.0, minY = 1.0
    for time in stride(from: 0.5, through: 9.4, by: 1.0 / 120) {
        let state = SceneEvaluator.focus(edit: resolved, time: time)
        minX = min(minX, state.x); minY = min(minY, state.y)
    }
    // 从不越过边界（求值层钳制），且路径本身在 4 秒后稳稳停在墙上，不是被钳出来的。
    #expect(minX >= margin - 0.000001 && minY >= margin - 0.000001)
    let settled = resolved.focuses[0].camera(at: 5)
    #expect(abs(settled.x - margin) < 0.001 && abs(settled.y - margin) < 0.001)
}

@Test func manualShotStartsAimedAndDoesNotPanLateDuringPushIn() {
    var edit = VideoEdit(duration: 10)
    edit.focuses = [manualShot(start: 2, duration: 5)]
    let events = hold(CGPoint(x: 0.8, y: 0.3), start: 0, end: 10)
    let resolved = edit.resolvingTimelineFocus(events: events)
    let shot = resolved.focuses[0]
    // 起点即对准指针（取景框贴到右缘，指针在框内）；推近的 0.6 秒内相机中心纹丝不动，不存在"先按旧中心放大再横摇"。
    let aimed = shot.camera(at: 0)
    #expect(abs(aimed.x - (1 - 0.5 / 1.8)) < 0.000001 && abs(aimed.y - 0.3) < 0.05)
    for elapsed in stride(from: 0.0, through: 0.6, by: 0.05) {
        let camera = shot.camera(at: elapsed)
        #expect(abs(camera.x - aimed.x) < 0.000001 && abs(camera.y - aimed.y) < 0.000001)
    }
}

@Test func planningAndEvaluationAreDeterministicAndOrderIndependent() {
    var edit = VideoEdit(duration: 12)
    edit.focuses = [manualShot(start: 1, duration: 10, scale: 2.2)]
    var seed: UInt32 = 11
    func noise() -> Double { seed = seed &* 1103515245 &+ 12345; return Double(seed % 1000) / 1000 - 0.5 }
    let events = stride(from: 0.0, through: 12, by: 1.0 / 60).map { time in
        PointerSample(time: time, x: min(1, max(0, 0.2 + time / 20 + noise() * 0.05)), y: min(1, max(0, 0.5 + noise() * 0.1)), kind: .move)
    }
    let first = edit.resolvingTimelineFocus(events: events), second = edit.resolvingTimelineFocus(events: events)
    #expect(first.focuses[0].path == second.focuses[0].path)
    let times = stride(from: 0.0, through: 12, by: 0.037).map { $0 }
    let sequential = times.map { SceneEvaluator.focus(edit: first, time: $0) }
    var generator = SplitMix64(seed: 7)
    let shuffled = times.shuffled(using: &generator).map { time in (time, SceneEvaluator.focus(edit: first, time: time)) }
    for (time, state) in shuffled {
        let index = times.firstIndex(of: time)!
        #expect(sequential[index] == state)
    }
}
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@Test func smoothedCursorSitsOnTheRealCursorNotBehindIt() {
    // 匀速移动：相位补偿后平滑光标与真实位置的偏差远小于弹簧滞后本该产生的偏差。
    let samples = (0...300).map { PointerSample(time: Double($0) / 60, x: 0.1 + Double($0) / 60 * 0.15, y: 0.5, kind: .move) }
    let pointers = PointerTimeline(events: samples, cursorEmbedded: false)
    let timeline = TimelineIndex(clips: [VideoClip(sourceStart: 0, duration: 5)])
    var effects = PointerEffects(); effects.smoothing = 1.2
    let lag = PointerSpring.lag(smoothing: 1.2)
    #expect(lag > 0.1)
    for time in stride(from: 1.5, through: 4.0, by: 0.25) {
        let real = 0.1 + time * 0.15
        let x = pointers.frame(at: time, timeline: timeline, effects: effects).position?.x ?? 0
        #expect(abs(x - real) < 0.15 * lag * 0.35, "t=\(time) 偏差 \(x - real)，未补偿时约 \(0.15 * lag)")
    }
}

@Test func jitterNotchDropsSmallReversalsButKeepsSlowStraightMotion() {
    let jitter = [PointerSample(time: 0, x: 0.5, y: 0.5, kind: .move), PointerSample(time: 0.02, x: 0.508, y: 0.5, kind: .move),
                  PointerSample(time: 0.04, x: 0.5, y: 0.5, kind: .move), PointerSample(time: 0.06, x: 0.507, y: 0.5, kind: .move), PointerSample(time: 0.08, x: 0.5, y: 0.5, kind: .move)]
    #expect(PointerTimeline.removingJitter(jitter).count == 3)
    let slow = (0...30).map { PointerSample(time: Double($0) / 60, x: 0.2 + Double($0) * 0.003, y: 0.5, kind: .move) }
    #expect(PointerTimeline.removingJitter(slow).count == slow.count)
    // 大幅折返是真实动作，不能删。
    let bigTurn = [PointerSample(time: 0, x: 0.2, y: 0.5, kind: .move), PointerSample(time: 0.05, x: 0.6, y: 0.5, kind: .move), PointerSample(time: 0.1, x: 0.2, y: 0.5, kind: .move)]
    #expect(PointerTimeline.removingJitter(bigTurn).count == 3)
}

@Test func shortLivedCursorShapeBlipsAreDebouncedButRealHoversStay() {
    func sample(_ time: Double, _ shape: PointerShape) -> PointerSample {
        var sample = PointerSample(time: time, x: 0.3, y: 0.4, kind: .move); sample.shape = shape; return sample
    }
    let blip = PointerAppearance(events: [sample(0, .arrow), sample(1, .pointer), sample(1.1, .arrow), sample(3, .pointer), sample(4, .arrow)])
    var frame = PointerFrame()
    blip.apply(to: &frame, time: 1.05, start: 0, end: 5, effects: PointerEffects())
    #expect(frame.shape == .arrow && frame.previousShape == nil)
    frame = PointerFrame()
    blip.apply(to: &frame, time: 3.5, start: 0, end: 5, effects: PointerEffects())
    #expect(frame.shape == .pointer)
}

import Foundation
import CoreGraphics
import Testing
@testable import EditingCore

/// 对照 Cap 整理出的几条镜头 / 光标算法细化：前瞻随响应推导、拖拽档、墙面停住、起点预瞄、纯函数可复现、
/// 光标平滑相位补偿、抖动陷波、短命形状去抖。
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

@Test func lookaheadFollowsTheResponseSliderSoFasterSpringsLagLess() {
    // 同一段匀速右移，响应更快（ω 更大）的镜头在同一时刻应更靠近指针；两者都不能落后指针超过安全区半宽。
    var edit = VideoEdit(duration: 10)
    edit.focuses = [manualShot(start: 1, duration: 8, scale: 2.0)]
    let events = hold(CGPoint(x: 0.3, y: 0.5), start: 0, end: 3) + moves(from: CGPoint(x: 0.3, y: 0.5), to: CGPoint(x: 0.8, y: 0.5), start: 3, end: 6) + hold(CGPoint(x: 0.8, y: 0.5), start: 6, end: 10)
    func cameraX(response: Double, at time: Double) -> Double {
        var value = edit; var style = AutoFocusStyle(); style.panResponse = response; value.focusStyle = style
        return SceneEvaluator.focus(edit: value.resolvingTimelineFocus(events: events), time: time).x
    }
    let pointer = 0.3 + 0.5 * (5.0 - 3) / 3
    let quick = cameraX(response: 0.3, at: 5), slow = cameraX(response: 1.2, at: 5)
    #expect(abs(pointer - quick) <= abs(pointer - slow) + 0.02)
    #expect(pointer - quick < 0.25 * 0.62 + 0.03 && pointer - slow < 0.25 * 0.62 + 0.06)
}

@Test func draggingUsesTheStifferSpringAndSettlesSooner() {
    // 按住拖动时弹簧更硬：同样一次小幅跳出安全区（限速之内），拖拽中的相机更早到位。
    func events(drag: Bool) -> [PointerSample] {
        var result = hold(CGPoint(x: 0.3, y: 0.5), start: 0, end: 3) + hold(CGPoint(x: 0.5, y: 0.5), start: 3.02, end: 8)
        if drag {
            result.append(PointerSample(time: 1, x: 0.3, y: 0.5, kind: .click))
            result.append(PointerSample(time: 7, x: 0.5, y: 0.5, kind: .release))
            result.sort { $0.time < $1.time }
        }
        return result
    }
    let dragged = events(drag: true)
    #expect(SmartFollowPlanner.dragIntervals(clicks: dragged.filter { $0.kind == .click }, samples: dragged) == [1...7])
    var edit = VideoEdit(duration: 8)
    edit.focuses = [manualShot(start: 0.5, duration: 7, scale: 2.0)]
    func arrival(_ samples: [PointerSample]) -> Double {
        let resolved = edit.resolvingTimelineFocus(events: samples)
        let target = resolved.focuses[0].camera(at: 6).x
        for time in stride(from: 2.5, through: 6.0, by: 1.0 / 240) where SceneEvaluator.focus(edit: resolved, time: time).x >= target - 0.004 { return time }
        return .infinity
    }
    let withDrag = arrival(dragged), withoutDrag = arrival(events(drag: false))
    #expect(withDrag.isFinite && withoutDrag.isFinite && withDrag < withoutDrag)
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
    let aimed = AutoFocus.clamp(CGPoint(x: 0.8, y: 0.3), scale: 1.8)
    // 起点即对准指针；推近的 0.6 秒内相机中心纹丝不动，不存在"先按旧中心放大再横摇"。
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

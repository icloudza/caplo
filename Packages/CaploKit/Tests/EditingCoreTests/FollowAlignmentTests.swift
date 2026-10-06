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


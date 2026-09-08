import Foundation
import CoreGraphics
import Testing
@testable import EditingCore

/// 无点击的手动讲解镜头：推近到指针所在并跟随；相邻镜头直接平移衔接；重叠镜头分层混合无跳变；
/// 快速横跨追得上、原地抖动不动、离开安全区只回到内区、起点落在指针将要到的位置。
private func moves(from a: CGPoint, to b: CGPoint, start: Double, end: Double, rate: Double = 60) -> [PointerSample] {
    stride(from: start, through: end, by: 1 / rate).map { time in
        let progress = (time - start) / max(0.0001, end - start)
        return PointerSample(time: time, x: a.x + (b.x - a.x) * progress, y: a.y + (b.y - a.y) * progress, kind: .move)
    }
}
private func hold(_ p: CGPoint, start: Double, end: Double) -> [PointerSample] { moves(from: p, to: p, start: start, end: end) }

private func manualShot(start: Double, duration: Double, scale: Double = 1.8, x: Double = 0.5, y: Double = 0.5, follows: Bool = true) -> FocusSegment {
    var shot = FocusSegment(start: start, duration: duration, x: x, y: y, scale: scale)
    shot.timelineStart = start; shot.followsTimeline = follows; shot.easeIn = 0.6; shot.easeOut = 0.7
    return shot
}
private func maxStep(_ edit: VideoEdit, from: Double, to: Double, rate: Double = 240) -> (position: Double, scale: Double) {
    var previous = SceneEvaluator.focus(edit: edit, time: from)
    var position = 0.0, scale = 0.0
    for time in stride(from: from + 1 / rate, through: to, by: 1 / rate) {
        let state = SceneEvaluator.focus(edit: edit, time: time)
        position = max(position, hypot(state.x - previous.x, state.y - previous.y)); scale = max(scale, abs(state.scale - previous.scale))
        previous = state
    }
    return (position, scale)
}

@Test func manualShotFollowsPointerWithoutAnyClick() {
    var edit = VideoEdit(duration: 20)
    edit.focuses = [manualShot(start: 2, duration: 7)]
    let events = hold(CGPoint(x: 0.42, y: 0.3), start: 0, end: 3) + moves(from: CGPoint(x: 0.42, y: 0.3), to: CGPoint(x: 0.75, y: 0.3), start: 3, end: 6) + hold(CGPoint(x: 0.75, y: 0.3), start: 6, end: 20)
    let resolved = edit.resolvingTimelineFocus(events: events)
    let shot = try! #require(resolved.focuses.first)
    #expect(shot.sampledPath == true && (shot.path?.count ?? 0) > 2)
    let settled = SceneEvaluator.focus(edit: resolved, time: 2.8)
    // 推近落在指针附近，而不是画面中心。
    #expect(abs(settled.x - 0.42) < 0.05 && abs(settled.y - max(0.3, 0.5 / settled.scale)) < 0.05)
    let later = SceneEvaluator.focus(edit: resolved, time: 8.5)
    #expect(later.x > settled.x + 0.12)
    #expect(maxStep(resolved, from: 2, to: 9).position < 0.006)
}

@Test func adjacentShotsLinkWithoutZoomingOutAndDistantOnesStillDo() {
    var edit = VideoEdit(duration: 14)
    edit.focuses = [manualShot(start: 1, duration: 5, scale: 1.8, x: 0.3, y: 0.3, follows: false),
                    manualShot(start: 6.4, duration: 5.6, scale: 2.2, x: 0.7, y: 0.7, follows: false)]
    let links = SceneEvaluator.links(edit: edit)
    #expect(links[edit.focuses[0].id]?.next == edit.focuses[1].id)
    var lowest = 9.0
    for time in stride(from: 5.5, through: 7.5, by: 1.0 / 120) { lowest = min(lowest, SceneEvaluator.focus(edit: edit, time: time).scale) }
    #expect(lowest > 1.79)
    // 衔接期间倍率从 1.8 平滑到 2.2、位置从前一个平移到后一个：两个固定镜头相距 0.57，0.6 秒平移过去
    // 每 1/240 秒最多走 0.008，是平滑曲线的峰值速度，不是跳变（跳变会是 0.5 一步到位）。
    let step = maxStep(edit, from: 5.5, to: 7.5)
    #expect(step.position < 0.012 && step.scale < 0.02)
    let middle = SceneEvaluator.focus(edit: edit, time: 6.7)
    #expect(middle.scale > 1.8 && middle.scale < 2.2 && middle.x > 0.3 && middle.x < 0.7)
    // 间隔大于合并间隔：照常拉远再推近。
    edit.focuses[1].timelineStart = 7.5; edit.focuses[1].start = 7.5
    #expect(SceneEvaluator.links(edit: edit).isEmpty)
    #expect(SceneEvaluator.focus(edit: edit, time: 6.6).scale == 1)
}

@Test func overlappingManualShotCrossfadesOverTheAutomaticOne() {
    var edit = VideoEdit(duration: 12)
    var automatic = FocusSegment(start: 2, duration: 6, x: 0.2, y: 0.2, scale: 1.6, automatic: true)
    automatic.easeIn = 0.6; automatic.easeOut = 0.7
    edit.focuses = [automatic, manualShot(start: 4, duration: 3, scale: 2.4, x: 0.8, y: 0.8, follows: false)]
    let step = maxStep(edit, from: 1.5, to: 8.5)
    #expect(step.position < 0.012 && step.scale < 0.02)
    let inside = SceneEvaluator.focus(edit: edit, time: 5.5)
    #expect(abs(inside.scale - 2.4) < 0.001 && abs(inside.x - (1 - 0.5 / 2.4)) < 0.001)
    let before = SceneEvaluator.focus(edit: edit, time: 3.5)
    #expect(abs(before.scale - 1.6) < 0.001)
}

@Test func fastSweepCatchesUpAndStaysContinuous() {
    var edit = VideoEdit(duration: 16)
    edit.focuses = [manualShot(start: 1, duration: 13, scale: 2.0)]
    let events = hold(CGPoint(x: 0.2, y: 0.5), start: 0, end: 4) + moves(from: CGPoint(x: 0.2, y: 0.5), to: CGPoint(x: 0.85, y: 0.5), start: 4, end: 4.25)
        + hold(CGPoint(x: 0.85, y: 0.5), start: 4.25, end: 8) + moves(from: CGPoint(x: 0.85, y: 0.5), to: CGPoint(x: 0.15, y: 0.85), start: 8, end: 8.3) + hold(CGPoint(x: 0.15, y: 0.85), start: 8.3, end: 16)
    let resolved = edit.resolvingTimelineFocus(events: events)
    var outside = 0.0
    let probe = PointerSpeedProbe(samples: events)
    for time in stride(from: 1.7, through: 13.0, by: 1.0 / 120) {
        let state = SceneEvaluator.focus(edit: resolved, time: time)
        guard let pointer = probe.position(at: time) else { continue }
        let half = 0.5 / state.scale
        if abs(pointer.x - state.x) > half || abs(pointer.y - state.y) > half { outside += 1.0 / 120 }
    }
    // 两次 0.25 秒的整屏横跨，指针在视口外的累计时间不到 0.6 秒（原先约 2 秒）。
    #expect(outside < 0.6)
    let step = maxStep(resolved, from: 1, to: 14)
    #expect(step.position < 0.02 && step.scale < 0.02)
}

@Test func readingJitterKeepsTheCameraStill() {
    var edit = VideoEdit(duration: 12)
    edit.focuses = [manualShot(start: 1, duration: 9, scale: 2.5)]
    var seed: UInt32 = 7
    func noise() -> Double { seed = seed &* 1103515245 &+ 12345; return Double(seed % 1000) / 1000 - 0.5 }
    let events = stride(from: 0.0, through: 12, by: 1.0 / 60).map { PointerSample(time: $0, x: 0.5 + noise() * 0.012, y: 0.45 + noise() * 0.012, kind: .move) }
    let resolved = edit.resolvingTimelineFocus(events: events)
    var travel = 0.0, previous = SceneEvaluator.focus(edit: resolved, time: 1.8)
    for time in stride(from: 1.8, through: 9.3, by: 1.0 / 60) {
        let state = SceneEvaluator.focus(edit: resolved, time: time)
        travel += hypot(state.x - previous.x, state.y - previous.y); previous = state
    }
    #expect(travel < 0.03)
}

@Test func leavingTheSafeZoneRecentersOnlyToTheInnerZone() {
    var edit = VideoEdit(duration: 12)
    edit.focuses = [manualShot(start: 1, duration: 10)]
    let events = hold(CGPoint(x: 0.5, y: 0.5), start: 0, end: 3) + moves(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.85, y: 0.5), start: 3, end: 3.6) + hold(CGPoint(x: 0.85, y: 0.5), start: 3.6, end: 12)
    let resolved = edit.resolvingTimelineFocus(events: events)
    let settled = SceneEvaluator.focus(edit: resolved, time: 7)
    // 光标停在 0.85：相机只把它带回内区边缘（0.85 − 0.5 / 1.8 × 0.42 ≈ 0.733），不整轴回中到 0.85。
    let expected = 0.85 - 0.5 / 1.8 * 0.42
    #expect(abs(settled.x - expected) < 0.03)
    #expect(settled.x < 0.8)
}

@Test func manualShotStartsWhereThePointerIsAboutToBe() {
    var edit = VideoEdit(duration: 10)
    edit.focuses = [manualShot(start: 2, duration: 5)]
    let events = hold(CGPoint(x: 0.2, y: 0.5), start: 0, end: 2) + moves(from: CGPoint(x: 0.2, y: 0.5), to: CGPoint(x: 0.6, y: 0.5), start: 2, end: 3) + hold(CGPoint(x: 0.6, y: 0.5), start: 3, end: 10)
    let resolved = edit.resolvingTimelineFocus(events: events)
    let shot = try! #require(resolved.focuses.first)
    // 推近完成六成处（2 + 0.36 秒）指针在 0.344；起点取它而不是按下那一刻的 0.2。
    let initial = shot.camera(at: 0)
    #expect(abs(initial.x - 0.344) < 0.03)
}

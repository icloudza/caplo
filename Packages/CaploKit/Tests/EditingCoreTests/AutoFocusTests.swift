import Foundation
import CoreGraphics
import Testing
@testable import EditingCore

/// 用合成的点击与光标轨迹验证自动聚焦：一次连续操作只推近一次、相机以最小幅度平移并保持连续，
/// 空闲后拉远，倍率随点击分散度放宽；求值在任意时刻都无跳变。
private func moves(from a: CGPoint, to b: CGPoint, start: Double, end: Double, rate: Double = 60) -> [PointerSample] {
    stride(from: start, through: end, by: 1 / rate).map { time in
        let progress = (time - start) / max(0.0001, end - start)
        return PointerSample(time: time, x: a.x + (b.x - a.x) * progress, y: a.y + (b.y - a.y) * progress, kind: .move)
    }
}

private func maxStep(_ edit: VideoEdit, from: Double, to: Double, rate: Double = 240) -> (position: Double, scale: Double) {
    var previous = SceneEvaluator.focus(edit: edit, time: from)
    var position = 0.0, scale = 0.0
    for time in stride(from: from + 1 / rate, through: to, by: 1 / rate) {
        let state = SceneEvaluator.focus(edit: edit, time: time)
        position = max(position, hypot(state.x - previous.x, state.y - previous.y))
        scale = max(scale, abs(state.scale - previous.scale))
        previous = state
    }
    return (position, scale)
}

@Test func consecutiveClicksShareOneShotAndCameraPansMinimally() {
    let clicks = [PointerSample(time: 2, x: 0.2, y: 0.25, kind: .click), PointerSample(time: 3.2, x: 0.85, y: 0.8, kind: .click)]
    var edit = VideoEdit(duration: 12)
    edit.focuses = AutoFocus.generate(events: clicks, duration: 12)
    #expect(edit.focuses.count == 1)
    let shot = edit.focuses[0]
    #expect(shot.automatic && shot.path != nil && shot.easeIn != nil)
    #expect(abs(shot.start - 1.65) < 0.001)
    // 第一下点击落在推近过程中，推近完成后视口以点击为中心（贴边时钳在视口边距上）；
    // 两次点击相距很远，倍率按分散度放宽到 1.45。
    let settled = SceneEvaluator.focus(edit: edit, time: 2.4)
    #expect(settled.scale > 1.3 && settled.scale < 1.6)
    #expect(abs(settled.x - max(0.2, 0.5 / settled.scale)) < 0.02 && abs(settled.y - max(0.25, 0.5 / settled.scale)) < 0.02)
    // 第二下点击后相机把目标带回视口内区，而不是直接把点击放到正中央。
    let panned = SceneEvaluator.focus(edit: edit, time: 4.3)
    #expect(abs(panned.x - 0.85) <= 0.5 / panned.scale + 0.001 && abs(panned.y - 0.8) <= 0.5 / panned.scale + 0.001)
    #expect(panned.x < 0.85 && panned.y < 0.8)
    // 空闲后拉远。
    #expect(SceneEvaluator.focus(edit: edit, time: shot.start + shot.duration + 0.01).scale == 1)
    #expect(SceneEvaluator.focus(edit: edit, time: shot.start + shot.duration - 0.001).scale < 1.05)
    let step = maxStep(edit, from: shot.start - 0.1, to: shot.start + shot.duration + 0.1)
    // 两次点击相距大半个画面，追赶阶段相机限速放宽到 2.2 画面宽 / 秒，每 1/240 秒最多走 0.009；连续曲线，不是跳变。
    #expect(step.position < 0.012 && step.scale < 0.02)
}

@Test func idleGapSplitsShotsAndScatteredClicksWidenTheView() {
    let clicks = [PointerSample(time: 1, x: 0.5, y: 0.5, kind: .click), PointerSample(time: 8, x: 0.5, y: 0.5, kind: .click)]
    let shots = AutoFocus.generate(events: clicks, duration: 20)
    #expect(shots.count == 2 && shots[0].start + shots[0].duration < shots[1].start)
    let scattered = [PointerSample(time: 1, x: 0.1, y: 0.1, kind: .click), PointerSample(time: 1.6, x: 0.9, y: 0.9, kind: .click), PointerSample(time: 2.2, x: 0.1, y: 0.9, kind: .click)]
    let wide = AutoFocus.generate(events: scattered, duration: 20)
    #expect(wide.count == 1 && wide[0].scale < 1.6)
    let tight = AutoFocus.generate(events: [PointerSample(time: 1, x: 0.4, y: 0.4, kind: .click), PointerSample(time: 1.6, x: 0.42, y: 0.41, kind: .click)], duration: 20)
    #expect(tight.count == 1 && tight[0].scale == 1.8 && tight[0].path == nil)
}

@Test func cursorLeavingSafeZoneIsFollowedGentlyAndStaysInsideFrame() {
    var events = [PointerSample(time: 1, x: 0.5, y: 0.5, kind: .click)]
    events += moves(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.95, y: 0.5), start: 1.2, end: 2.0)
    events += moves(from: CGPoint(x: 0.95, y: 0.5), to: CGPoint(x: 0.95, y: 0.5), start: 2.0, end: 3.0)
    events.append(PointerSample(time: 3.0, x: 0.95, y: 0.5, kind: .click))
    var edit = VideoEdit(duration: 10)
    edit.focuses = AutoFocus.generate(events: events, duration: 10)
    let shot = try! #require(edit.focuses.first)
    #expect((shot.path?.count ?? 0) >= 2)
    let before = SceneEvaluator.focus(edit: edit, time: 1.6), after = SceneEvaluator.focus(edit: edit, time: 3.4)
    #expect(after.x > before.x + 0.1)
    for time in stride(from: shot.start, through: shot.start + shot.duration, by: 0.05) {
        let state = SceneEvaluator.focus(edit: edit, time: time)
        #expect(state.x >= 0.5 / state.scale - 0.0001 && state.x <= 1 - 0.5 / state.scale + 0.0001)
    }
    #expect(maxStep(edit, from: shot.start, to: shot.start + shot.duration).position < 0.006)
}

@Test func keyframeMotionSurvivesEditingAndValidation() throws {
    var edit = VideoEdit(duration: 10)
    edit.focuses = AutoFocus.generate(events: [PointerSample(time: 2, x: 0.2, y: 0.2, kind: .click), PointerSample(time: 3, x: 0.8, y: 0.8, kind: .click)], duration: 10)
    try edit.validate(sourceDuration: 10)
    let decoded = try JSONDecoder().decode(VideoEdit.self, from: JSONEncoder().encode(edit))
    #expect(decoded == edit)
    // 起点向后拖 1 秒：内部运动的绝对时间不变。
    let id = edit.focuses[0].id
    let spans = edit.focusSpans()
    edit.materializeFocus(spans[0])
    let reference = SceneEvaluator.focus(edit: edit, time: 3.6)
    edit.dragFocus(id: id, edge: .leading, delta: 1)
    try edit.validate(sourceDuration: 10)
    let shifted = SceneEvaluator.focus(edit: edit, time: 3.6)
    #expect(abs(shifted.x - reference.x) < 0.05 && abs(shifted.y - reference.y) < 0.05)
    // 关键帧非法时拒绝。
    edit.focuses[0].path?[0].scale = 9
    #expect(throws: EditError.self) { try edit.validate(sourceDuration: 10) }
}

@Test func shadowParametersRoundTripAndDefaultForOldFiles() throws {
    var edit = VideoEdit(duration: 4)
    edit.layout.shadowOpacity = 0.5; edit.layout.shadowBlur = 20; edit.layout.shadowOffset = -6
    let decoded = try JSONDecoder().decode(VideoEdit.self, from: JSONEncoder().encode(edit))
    #expect(decoded.layout == edit.layout)
    let legacy = Data(#"{"ratio":"16:9","background":"鸢尾","padding":40,"cornerRadius":12,"shadow":true}"#.utf8)
    let layout = try JSONDecoder().decode(CanvasLayout.self, from: legacy)
    #expect(layout.shadowOpacity == CanvasLayout.defaultShadowOpacity && layout.shadowBlur == CanvasLayout.defaultShadowBlur && layout.shadowOffset == CanvasLayout.defaultShadowOffset)
    edit.layout.shadowBlur = 500
    #expect(throws: EditError.self) { try edit.validate(sourceDuration: 4) }
}

@Test func latestFollowPreviewsRecordedMotionAndNeverRestartsAtTargets() throws {
    var events = [PointerSample(time: 1, x: 0.5, y: 0.5, kind: .click)]
    events += moves(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.9, y: 0.5), start: 1.2, end: 2.2)
    events += moves(from: CGPoint(x: 0.9, y: 0.5), to: CGPoint(x: 0.2, y: 0.5), start: 2.2, end: 3.5)
    events.append(PointerSample(time: 3.5, x: 0.2, y: 0.5, kind: .click))
    var noPrediction = AutoFocusStyle(); noPrediction.prediction = 0
    var withPrediction = noPrediction; withPrediction.prediction = 0.25
    let plain = try #require(AutoFocus.generate(events: events, duration: 6, style: noPrediction).first)
    let predictive = try #require(AutoFocus.generate(events: events, duration: 6, style: withPrediction).first)
    #expect(predictive.sampledPath == true)
    let t = 1.9 - predictive.start
    #expect(predictive.camera(at: t).x > plain.camera(at: t).x)
    let samples = (0..<500).map { predictive.camera(at: Double($0) / 120).x }
    let speeds = zip(samples, samples.dropFirst()).map { ($1 - $0) * 120 }
    #expect(speeds.allSatisfy { abs($0) <= 0.81 })
    let changes = zip(speeds, speeds.dropFirst()).map { abs($1 - $0) }
    #expect((changes.max() ?? 0) < 0.15)
}

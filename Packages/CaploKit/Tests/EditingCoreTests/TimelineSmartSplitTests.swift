import Foundation
import Testing
@testable import EditingCore

@Test func splittingContinuousMediaKeepsOneSmartFocusAndIdenticalSourceDrivenMotion() throws {
    // 源素材从第 100 秒开始，确保验证成片时间与源事件时间的真实映射，而非恰好同值。
    var clip = VideoClip(sourceStart: 100, duration: 8); clip.timelineStart = 0
    var edit = VideoEdit(duration: 0); edit.clips = [clip]
    edit.prepareLayerEditing(camera: false, system: false, microphone: false)
    var focus = FocusSegment(start: 101, duration: 6, x: 0.3, y: 0.5)
    focus.timelineStart = 1; focus.targetClipID = clip.id; focus.followsTimeline = true
    edit.focuses = [focus]
    edit.moveLayer(focus.id, before: clip.id)
    edit.constrainTimelineFocuses()
    #expect(edit.focuses[0].targetClipID == clip.id)

    let events = (0...480).map { frame in
        let elapsed = Double(frame) / 60
        return PointerSample(time: 100 + elapsed, x: 0.15 + elapsed * 0.0875,
                             y: 0.5 + sin(elapsed) * 0.1, kind: .move)
    }
    let before = edit.resolvingTimelineFocus(events: events)
    let beforePath = try #require(before.focuses[0].path)
    #expect((beforePath.map(\.x).max() ?? 0) - (beforePath.map(\.x).min() ?? 0) > 0.1)
    #expect(edit.focuses[0].path == nil)

    let tail = edit.splitMedia(.screen, id: clip.id, at: 4)
    #expect(tail != nil)
    edit.constrainTimelineFocuses()
    #expect(edit.clips.count == 2 && edit.focuses.count == 1)
    #expect(edit.focuses[0].id == focus.id && edit.focuses[0].timelineStart == 1 && edit.focuses[0].duration == 6)
    #expect(edit.focuses[0].targetClipID == nil && edit.focuses[0].followsTimeline == true)
    #expect(edit.focuses[0].path == nil && edit.duration == 8)

    let after = edit.resolvingTimelineFocus(events: events)
    // 剪切没有改动任何可见源画面，规划器应合并连续源区间，避免在新 UUID 处重置预测与惯性。
    #expect(after.focuses[0].path == beforePath)
    for frame in 0..<960 {
        let time = Double(frame) / 120
        #expect(edit.sourceTime(at: time) == before.sourceTime(at: time))
        let expected = SceneEvaluator.focus(edit: before, time: time)
        let actual = SceneEvaluator.focus(edit: after, time: time)
        #expect(abs(actual.x - expected.x) < 1e-10 && abs(actual.y - expected.y) < 1e-10)
        #expect(abs(actual.scale - expected.scale) < 1e-10)
    }
    try edit.validate(sourceDuration: 108)
    try after.validate(sourceDuration: 108)
}

@Test func manualTimelineFocusOverridesSourceAutomationAndManualRowsDecidePriority() throws {
    var clip = VideoClip(sourceStart: 100, duration: 8); clip.timelineStart = 0
    var edit = VideoEdit(duration: 0); edit.clips = [clip]
    let automatic = FocusSegment(start: 100, duration: 8, x: 0.7, y: 0.6, scale: 1.3, automatic: true)
    var smart = FocusSegment(start: 101, duration: 6, x: 0.3, y: 0.4, scale: 2)
    smart.timelineStart = 1; smart.followsTimeline = true
    var fixed = FocusSegment(start: 102, duration: 4, x: 0.65, y: 0.55, scale: 2.5)
    fixed.timelineStart = 2; fixed.followsTimeline = false
    edit.focuses = [smart, fixed, automatic]
    // 自动行即使位于最上层，也不能盖过用户设置；两个手动行才按层级决定优先。
    edit.layerOrder = [automatic.id, smart.id, fixed.id, clip.id]
    let events = (0...480).map { frame in
        PointerSample(time: 100 + Double(frame) / 60, x: 0.25, y: 0.4, kind: .move)
    }
    let before = edit.resolvingTimelineFocus(events: events)
    var smartOnly = before; smartOnly.focuses.removeAll { $0.id != smart.id }
    #expect(SceneEvaluator.focus(edit: before, time: 3) == SceneEvaluator.focus(edit: smartOnly, time: 3))
    #expect(SceneEvaluator.focus(edit: before, time: 3).scale == 2)

    edit.moveLayer(fixed.id, before: smart.id)
    let after = edit.resolvingTimelineFocus(events: events)
    var fixedOnly = after; fixedOnly.focuses.removeAll { $0.id != fixed.id }
    #expect(SceneEvaluator.focus(edit: after, time: 3) == SceneEvaluator.focus(edit: fixedOnly, time: 3))
    #expect(SceneEvaluator.focus(edit: after, time: 3).scale == 2.5)
    #expect(SceneEvaluator.focus(edit: after, time: 1.5) == SceneEvaluator.focus(edit: smartOnly, time: 1.5))
    let times = [0.2, 1, 1.05, 1.5, 2, 2.01, 3, 5.99, 6, 6.95, 7, 7.8]
    expectSmartSceneEvaluationIsIndependentOfRequestOrder(before, times: times)
    expectSmartSceneEvaluationIsIndependentOfRequestOrder(after, times: times)
    try before.validate(sourceDuration: 108)
    try after.validate(sourceDuration: 108)
}

@Test func reorderingDiscontinuousVisibleMediaInvalidatesOnlyTheOccludedClipTarget() throws {
    var base = VideoClip(sourceStart: 100, duration: 8); base.timelineStart = 0
    var overlay = VideoClip(sourceStart: 200, duration: 3); overlay.timelineStart = 2
    var edit = VideoEdit(duration: 0); edit.clips = [base, overlay]
    // 旧源镜头仍关联 base；原镜头源范围即使包含覆盖画面的源时间，也必须检查可见素材 ID。
    var local = FocusSegment(start: 100, duration: 108, x: 0.3, y: 0.4, scale: 2)
    local.targetClipID = base.id
    var timeline = FocusSegment(start: 0, duration: 8, x: 0.5, y: 0.5, scale: 1.6)
    timeline.timelineStart = 0; timeline.followsTimeline = true
    edit.focuses = [timeline, local]
    edit.layerOrder = [local.id, timeline.id, overlay.id, base.id]
    let events = (0...480).map { frame in
        PointerSample(time: 100 + Double(frame) / 60, x: 0.25, y: 0.4, kind: .move)
    } + (0...180).map { frame in
        PointerSample(time: 200 + Double(frame) / 60, x: 0.75, y: 0.6, kind: .move)
    }
    let before = edit.resolvingTimelineFocus(events: events)
    #expect(before.sourceTime(at: 3) == 201)
    var localOnly = before; localOnly.focuses.removeAll { $0.id != local.id }
    #expect(SceneEvaluator.focus(edit: localOnly, time: 3) == FocusState())
    var timelineOnly = before; timelineOnly.focuses.removeAll { $0.id != timeline.id }
    #expect(SceneEvaluator.focus(edit: before, time: 3) == SceneEvaluator.focus(edit: timelineOnly, time: 3))
    #expect(SceneEvaluator.focus(edit: before, time: 3).scale == 1.6)

    edit.moveLayer(base.id, before: overlay.id)
    let after = edit.resolvingTimelineFocus(events: events)
    #expect(after.sourceTime(at: 3) == 103)
    localOnly = after; localOnly.focuses.removeAll { $0.id != local.id }
    #expect(SceneEvaluator.focus(edit: after, time: 3) == SceneEvaluator.focus(edit: localOnly, time: 3))
    #expect(SceneEvaluator.focus(edit: after, time: 3).scale == 2)
    let times = [0.1, 1.99, 2, 2.01, 3, 4.99, 5, 5.01, 7.8]
    expectSmartSceneEvaluationIsIndependentOfRequestOrder(before, times: times)
    expectSmartSceneEvaluationIsIndependentOfRequestOrder(after, times: times)
    try before.validate(sourceDuration: 208)
    try after.validate(sourceDuration: 208)
}

private func expectSmartSceneEvaluationIsIndependentOfRequestOrder(_ edit: VideoEdit, times: [Double]) {
    let reference = times.map { SceneEvaluator.focus(edit: edit, time: $0) }
    // 先向前、再跳跃、再倒退取帧；持久行序相同时，内部数组遍历顺序也不应改变结果。
    let interleaved = times.indices.filter { $0.isMultiple(of: 2) } + Array(times.indices.filter { !$0.isMultiple(of: 2) }.reversed())
    var reverseStorage = edit; reverseStorage.focuses.reverse()
    for index in interleaved + Array(times.indices.reversed()) {
        #expect(SceneEvaluator.focus(edit: edit, time: times[index]) == reference[index])
        #expect(SceneEvaluator.focus(edit: reverseStorage, time: times[index]) == reference[index])
    }
}

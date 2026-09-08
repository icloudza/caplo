import Foundation
import Testing
@testable import EditingCore

@Test func intelligentFocusContinuousSourceCutsProduceIdenticalPath() throws {
    let events = (0..<480).map { number in
        PointerSample(time: Double(number) / 60, x: 0.5 + sin(Double(number) / 45) * 0.22, y: 0.5, kind: number % 90 == 0 ? .click : .move)
    }
    var original = focusTimeline(clips: [focusClip(source: 0, start: 0, duration: 8)], duration: 8)
    var cut = original
    cut.clips = [focusClip(source: 0, start: 0, duration: 3), focusClip(source: 3, start: 3, duration: 5)]
    cut.layerOrder = cut.clips.reversed().map(\.id)
    let before = original
    original = original.resolvingTimelineFocus(events: events)
    let compiledCut = cut.resolvingTimelineFocus(events: events)
    #expect(original.focuses[0].path == compiledCut.focuses[0].path)
    #expect(before.focuses[0].path == nil && before.focuses[0].followsTimeline == true)
    #expect(abs(original.focuses[0].camera(at: 3 - 0.001).x - original.focuses[0].camera(at: 3 + 0.001).x) < 0.005)
    try original.validate(sourceDuration: 8)
}

@Test func intelligentFocusReorderedRepeatedSourcesHardCutAtExactBoundary() throws {
    let edit = focusTimeline(clips: [focusClip(source: 10, start: 0, duration: 2), focusClip(source: 0, start: 2, duration: 2), focusClip(source: 10, start: 4, duration: 2)], duration: 6)
    let result = edit.resolvingTimelineFocus(events: [pointer(0, 0.25, .click), pointer(10, 0.75, .click)])
    let focus = result.focuses[0]
    #expect(focus.camera(at: 2 - 0.000_001).x == 0.75)
    #expect(focus.camera(at: 2).x == 0.25)
    #expect(focus.camera(at: 4).x == 0.75)
    #expect(focus.path?.filter { $0.time == 2 }.count == 2)
    #expect(focus.path?.allSatisfy { $0.scale == 2 } == true)
    #expect(result == edit.resolvingTimelineFocus(events: [pointer(0, 0.25, .click), pointer(10, 0.75, .click)]))
    try result.validate(sourceDuration: 12)
}

@Test func intelligentFocusDropsOccludedEventsAndRestrictsBoundTarget() {
    let bottom = focusClip(source: 0, start: 0, duration: 4), top = focusClip(source: 10, start: 1, duration: 1)
    var edit = focusTimeline(clips: [bottom, top], duration: 4)
    edit.layerOrder = [top.id, bottom.id]
    let events = [pointer(0, 0.25, .click), pointer(1.2, 0.9, .click), pointer(2, 0.35, .click), pointer(10, 0.75, .click)]
    let compiled = edit.resolvingTimelineFocus(events: events)
    #expect(compiled.focuses[0].camera(at: 1).x == 0.75)
    #expect(abs(compiled.focuses[0].camera(at: 2).x - 0.35) < 0.000_001)
    edit.focuses[0].targetClipID = bottom.id
    let targeted = edit.resolvingTimelineFocus(events: events)
    #expect(targeted.focuses[0].camera(at: 1.5).x == 0.5)
    #expect(SceneEvaluator.focus(edit: targeted, time: 1.5).scale == 1)
}

@Test func intelligentFocusGapAndDifferentSourceWithoutEventsUseOwnFallback() {
    let edit = focusTimeline(clips: [focusClip(source: 0, start: 0, duration: 1), focusClip(source: 10, start: 3, duration: 1)], duration: 4)
    let compiled = edit.resolvingTimelineFocus(events: [pointer(0, 0.25, .click), pointer(9, 0.75, .click)])
    #expect(compiled.focuses[0].camera(at: 0.5).x == 0.25)
    #expect(compiled.focuses[0].camera(at: 1.5).x == 0.5)
    #expect(compiled.focuses[0].camera(at: 3.5).x == 0.5)
}

@Test func intelligentFocusDoesNotJumpToDistantFutureClick() {
    let edit = focusTimeline(clips: [focusClip(source: 0, start: 0, duration: 8)], duration: 8)
    let compiled = edit.resolvingTimelineFocus(events: [pointer(0, 0.4), pointer(5, 0.75, .click)])
    #expect(abs(compiled.focuses[0].camera(at: 0).x - 0.4) < 0.000_001)
    #expect(abs(compiled.focuses[0].camera(at: 3).x - 0.4) < 0.000_001)
    #expect(compiled.focuses[0].camera(at: 6).x > 0.6)
    let near = edit.resolvingTimelineFocus(events: [pointer(0, 0.4), pointer(0.39, 0.75, .click)])
    #expect(near.focuses[0].camera(at: 0).x == 0.75)
}

@Test func intelligentFocusMidClipUsesLastPositionButDoesNotReviveExitedCursor() {
    var edit = focusTimeline(clips: [focusClip(source: 10, start: 0, duration: 10)], duration: 3)
    edit.focuses[0].timelineStart = 4
    let recent = edit.resolvingTimelineFocus(events: [pointer(11, 0.3, .click)])
    #expect(abs(recent.focuses[0].camera(at: 0).x - 0.3) < 0.000_001)
    let outsideSource = edit.resolvingTimelineFocus(events: [pointer(9, 0.75, .click)])
    #expect(outsideSource.focuses[0].camera(at: 0).x == 0.5)
    let exited = edit.resolvingTimelineFocus(events: [pointer(11, 0.3, .click), pointer(12, 0, .exit)])
    #expect(exited.focuses[0].camera(at: 0).x == 0.5)
}

@Test func intelligentFocusStartingAfterContinuousCutKeepsSameRecordedPointerContext() {
    var uncut = focusTimeline(clips: [focusClip(source: 0, start: 0, duration: 8)], duration: 3)
    uncut.focuses[0].timelineStart = 4
    var cut = uncut
    cut.clips = [focusClip(source: 0, start: 0, duration: 3), focusClip(source: 3, start: 3, duration: 5)]
    cut.layerOrder = cut.clips.reversed().map(\.id)
    let events = [pointer(2.5, 0.3, .click)]
    #expect(uncut.resolvingTimelineFocus(events: events).focuses[0].path == cut.resolvingTimelineFocus(events: events).focuses[0].path)
    cut.focuses[0].targetClipID = cut.clips[1].id
    #expect(uncut.resolvingTimelineFocus(events: events).focuses[0].path == cut.resolvingTimelineFocus(events: events).focuses[0].path)
}

@Test func intelligentFocusExitFreezesAndWaitsForRealReentry() {
    let edit = focusTimeline(clips: [focusClip(source: 0, start: 0, duration: 6)], duration: 6)
    let compiled = edit.resolvingTimelineFocus(events: [pointer(0, 0.75, .click), pointer(1, 0, .exit), pointer(3, 0.25, .click)])
    let focus = compiled.focuses[0]
    #expect(focus.camera(at: 1 - 0.000_001).x == focus.camera(at: 1).x)
    #expect(focus.camera(at: 1).x == focus.camera(at: 2.99).x)
    #expect(focus.camera(at: 3).x == 0.75, "不能越过 exit 提前追逐重入点击")
    #expect(focus.camera(at: 4).x < 0.4)
}

@Test func intelligentFocusHoldFreezesAndFocusStartingInsideHoldUsesEndpointPointer() {
    var clip = focusClip(source: 0, start: 0, duration: 5); clip.mediaDuration = 1
    let edit = focusTimeline(clips: [clip], duration: 5)
    let beforeEnd = [pointer(0, 0.25, .click), pointer(0.8, 0.75)]
    let compiled = edit.resolvingTimelineFocus(events: beforeEnd + [pointer(1.2, 0.3, .click)])
    #expect(compiled.focuses[0].path == edit.resolvingTimelineFocus(events: beforeEnd).focuses[0].path)
    #expect(compiled.focuses[0].camera(at: 1).x == compiled.focuses[0].camera(at: 4.9).x)
    var late = edit
    late.focuses[0].timelineStart = 2; late.focuses[0].duration = 2
    let held = late.resolvingTimelineFocus(events: beforeEnd + [pointer(1.2, 0.3, .click)])
    #expect(held.focuses[0].camera(at: 0).x == 0.75 && held.focuses[0].camera(at: 1.9).x == 0.75)
}

@Test func intelligentFocusPreservesEnvelopeOffsetAndIgnoresInvalidEvents() throws {
    var edit = focusTimeline(clips: [focusClip(source: 0, start: 0, duration: 8)], duration: 3)
    edit.focuses[0].timelineStart = 2; edit.focuses[0].transitionOffset = 2; edit.focuses[0].transitionDuration = 6
    edit.focuses[0].easeIn = 0.8; edit.focuses[0].easeOut = 0.9; edit.focuses[0].easing = .demo
    let invalid = [pointer(.nan, 0.9, .click), pointer(-1, 0.75, .click), pointer(2, .nan), pointer(2.1, 2, .click)]
    let compiled = edit.resolvingTimelineFocus(events: invalid + [pointer(2, 0.3, .click)])
    #expect(compiled == edit.resolvingTimelineFocus(events: [pointer(2, 0.3, .click)]))
    #expect(compiled.focuses[0].path?.first?.time == 2)
    #expect(compiled.focuses[0].path?.last?.time == 5)
    #expect(compiled.focuses[0].transitionOffset == 2 && compiled.focuses[0].transitionDuration == 6)
    #expect(compiled.focuses[0].easeIn == 0.8 && compiled.focuses[0].easeOut == 0.9 && compiled.focuses[0].easing == .demo)
    try compiled.validate(sourceDuration: 8)
    var fixed = edit; fixed.focuses[0].followsTimeline = false
    #expect(fixed.resolvingTimelineFocus(events: [pointer(2, 0.75, .click)]) == fixed)
}

@Test func intelligentFocusOneHourHighFrequencyEventsRemainDynamicAndBounded() throws {
    let edit = focusTimeline(clips: [focusClip(source: 0, start: 0, duration: 3600)], duration: 3600)
    let events = (0..<216_000).map { number in
        pointer(Double(number) / 60, 0.5 + sin(Double(number) / 600) * 0.22, number % 600 == 0 ? .click : .move)
    }
    let compiled = edit.resolvingTimelineFocus(events: events)
    let path = try #require(compiled.focuses[0].path)
    #expect(path.count > 100 && path.count <= 190_000)
    #expect((path.map(\.x).max() ?? 0) - (path.map(\.x).min() ?? 0) > 0.15)
    #expect(path.allSatisfy { $0.time.isFinite && $0.x.isFinite })
    try compiled.validate(sourceDuration: 3600)
}

@Test func intelligentFocusVeryLongStaticTimelineDoesNotSampleEmptyTime() {
    let edit = focusTimeline(clips: [focusClip(source: 0, start: 0, duration: 1_000_000_000)], duration: 1_000_000_000)
    let compiled = edit.resolvingTimelineFocus(events: [])
    #expect(compiled.focuses[0].path?.count == 1)
    let farOutside = edit.resolvingTimelineFocus(events: [pointer(1_000_000_001, 0.75, .click)])
    #expect((farOutside.focuses[0].path?.count ?? 0) <= 2)
}

private func pointer(_ time: Double, _ x: Double, _ kind: PointerSample.Kind = .move) -> PointerSample {
    PointerSample(time: time, x: x, y: 0.5, kind: kind)
}
private func focusClip(source: Double, start: Double, duration: Double) -> VideoClip {
    var clip = VideoClip(sourceStart: source, duration: duration); clip.timelineStart = start; return clip
}
private func focusTimeline(clips: [VideoClip], duration: Double) -> VideoEdit {
    var edit = VideoEdit(duration: 0)
    edit.schemaVersion = 6; edit.clips = clips; edit.layerOrder = clips.map(\.id)
    var focus = FocusSegment(start: 0, duration: duration, x: 0.5, y: 0.5, scale: 2)
    focus.timelineStart = 0; focus.followsTimeline = true
    edit.focuses = [focus]
    return edit
}

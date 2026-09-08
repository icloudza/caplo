import Foundation
import Testing
@testable import EditingCore

@Test func singleScreenFocusBodyAndBothEdgesStayInsideTheScreenEnvelope() throws {
    var edit = VideoEdit(duration: 4)
    edit.clips[0].timelineStart = 3
    var audio = VideoClip(sourceStart: 0, duration: 4); audio.timelineStart = 12
    edit.microphoneClips = [audio]
    var focus = FocusSegment(start: 1, duration: 2, x: 0.5, y: 0.5)
    focus.timelineStart = 4; focus.targetClipID = edit.clips[0].id
    edit.focuses = [focus]
    #expect(edit.focusBounds(for: focus.id) == 3...7)
    #expect(edit.duration == 16)

    edit.dragFocus(id: focus.id, edge: .body, delta: 100)
    #expect(edit.focuses[0].timelineStart == 5 && edit.focuses[0].duration == 2)
    edit.dragFocus(id: focus.id, edge: .body, delta: -100)
    #expect(edit.focuses[0].timelineStart == 3 && edit.focuses[0].duration == 2)
    edit.dragFocus(id: focus.id, edge: .trailing, delta: 100)
    #expect(edit.focuses[0].timelineStart == 3 && edit.focuses[0].duration == 4)
    edit.dragFocus(id: focus.id, edge: .leading, delta: -100)
    #expect(edit.focuses[0].timelineStart == 3 && edit.focuses[0].duration == 4)
    edit.dragFocus(id: focus.id, edge: .leading, delta: 100)
    #expect(abs(edit.focuses[0].duration - 1.0 / 30) < 1e-10)
    #expect(abs(edit.focuses[0].editingStart + edit.focuses[0].duration - 7) < 1e-10)
    try edit.validate(sourceDuration: 4)

    // 声音延伸到 16 秒也不能给只关联 3...7 秒画面的聚焦提供额外时长。
    edit.focuses[0].timelineStart = 6; edit.focuses[0].duration = 2
    #expect(throws: EditError.self) { try edit.validate(sourceDuration: 4) }
}

@Test func unlinkedFocusUsesScreenEnvelopeInsteadOfOtherMediaDuration() throws {
    var first = VideoClip(sourceStart: 0, duration: 2); first.timelineStart = 2
    var second = VideoClip(sourceStart: 2, duration: 2); second.timelineStart = 8
    var audio = VideoClip(sourceStart: 0, duration: 4); audio.timelineStart = 16
    var edit = VideoEdit(duration: 0); edit.clips = [first, second]; edit.systemClips = [audio]
    var focus = FocusSegment(start: 0, duration: 1, x: 0.5, y: 0.5); focus.timelineStart = 3
    edit.focuses = [focus]
    #expect(edit.focusBounds(for: focus.id) == 2...10)
    edit.dragFocus(id: focus.id, edge: .body, delta: 100)
    #expect(edit.focuses[0].timelineStart == 9)
    edit.dragFocus(id: focus.id, edge: .trailing, delta: 100)
    #expect(edit.focuses[0].duration == 1)
    edit.dragFocus(id: focus.id, edge: .leading, delta: -100)
    #expect(edit.focuses[0].timelineStart == 2 && edit.focuses[0].duration == 8)
    #expect(edit.duration == 20)
    try edit.validate(sourceDuration: 4)
}

@Test func legacyOutOfBoundsFocusIsCroppedWithoutRestartingItsAnimation() throws {
    var edit = VideoEdit(duration: 4); edit.clips[0].timelineStart = 3
    var focus = FocusSegment(start: 1, duration: 8, x: 0.3, y: 0.5)
    focus.timelineStart = 1; focus.targetClipID = edit.clips[0].id
    focus.transitionOffset = 1; focus.transitionDuration = 10
    focus.path = [FocusKeyframe(time: 0, x: 0.3, y: 0.5, scale: 1.8, move: 0),
                  FocusKeyframe(time: 3, x: 0.5, y: 0.5, scale: 2, move: 1),
                  FocusKeyframe(time: 7, x: 0.7, y: 0.5, scale: 1.8, move: 1)]
    focus.sampledPath = true
    edit.focuses = [focus]
    let before = [4.0, 5, 6].map { SceneEvaluator.focus(edit: edit, time: $0) }
    #expect(edit.duration == 7)
    var decoded = try JSONDecoder().decode(VideoEdit.self, from: JSONEncoder().encode(edit))
    decoded.constrainTimelineFocuses()
    #expect(decoded.focuses[0].timelineStart == 3 && decoded.focuses[0].duration == 4)
    #expect(decoded.focuses[0].transitionOffset == 3 && decoded.focuses[0].transitionDuration == 10)
    #expect(decoded.focuses[0].path == focus.path)
    #expect([4.0, 5, 6].map { SceneEvaluator.focus(edit: decoded, time: $0) } == before)
    try decoded.validate(sourceDuration: 4)
    let normalized = decoded
    decoded.constrainTimelineFocuses()
    #expect(decoded == normalized)
}

@Test func shorteningOrDeletingMediaCannotLeaveAnEffectOnlyTail() throws {
    var edit = VideoEdit(duration: 10.1)
    edit.clips[0].timelineStart = 0
    var focus = FocusSegment(start: 8, duration: 4, x: 0.5, y: 0.5)
    focus.timelineStart = 8; focus.targetClipID = edit.clips[0].id
    edit.focuses = [focus]
    #expect(edit.duration == 10.1)
    edit.constrainTimelineFocuses()
    #expect(abs(edit.focuses[0].duration - 2.1) < 1e-10)
    edit.clips[0].duration = 9
    #expect(edit.duration == 9)
    edit.constrainTimelineFocuses()
    #expect(edit.focuses[0].duration == 1)
    try edit.validate(sourceDuration: 10.1)
    edit.clips.removeAll()
    #expect(edit.duration == 0)
    edit.constrainTimelineFocuses()
    #expect(edit.focuses.isEmpty)
    try edit.validate(sourceDuration: 10.1)
}

@Test func orphanedFocusBecomesTimelineScopedWhileEntirelyOutsideFocusIsRemoved() throws {
    var edit = VideoEdit(duration: 4)
    edit.clips[0].timelineStart = 3
    var orphan = FocusSegment(start: 0, duration: 2, x: 0.5, y: 0.5)
    orphan.timelineStart = 3; orphan.targetClipID = UUID()
    var outside = orphan; outside.id = UUID(); outside.targetClipID = edit.clips[0].id; outside.timelineStart = 8
    edit.focuses = [orphan, outside]
    edit.constrainTimelineFocuses()
    #expect(edit.focuses.count == 1 && edit.focuses[0].id == orphan.id && edit.duration == 7)
    #expect(edit.focuses[0].timelineStart == 3 && edit.focuses[0].duration == 2)
    #expect(edit.focuses[0].targetClipID == nil && edit.focuses[0].followsTimeline == true)
    try edit.validate(sourceDuration: 4)
}

@Test(arguments: [VideoEdit.FocusDragEdge.body, .leading, .trailing])
func movingOrResizingAcrossAClipBoundarySwitchesToTimelineFollowing(edge: VideoEdit.FocusDragEdge) throws {
    var edit = crossClipFocusFixture()
    let id = edit.focuses[0].id
    let delta: Double
    switch edge {
    case .body: delta = 4
    case .leading:
        edit.focuses[0].timelineStart = 5; edit.focuses[0].targetClipID = edit.clips[1].id
        delta = -3
    case .trailing: delta = 2
    }
    #expect(edit.focusBounds(for: id) == 0...12)
    edit.dragFocus(id: id, edge: edge, delta: delta)
    let focus = edit.focuses[0]
    switch edge {
    case .body: #expect(focus.timelineStart == 5 && focus.duration == 2)
    case .leading: #expect(focus.timelineStart == 2 && focus.duration == 5)
    case .trailing: #expect(focus.timelineStart == 1 && focus.duration == 4)
    }
    #expect(focus.targetClipID == nil && focus.followsTimeline == true && !focus.automatic)
    #expect(focus.path == nil && focus.sampledPath == nil)
    #expect(focus.transitionOffset == nil && focus.transitionDuration == nil)
    #expect(edit.duration == 12)
    try edit.validate(sourceDuration: 12)
}

@Test func spanningThreeClipsAndReturningInsideOneDoesNotRebindTheFocus() throws {
    var edit = crossClipFocusFixture()
    let id = edit.focuses[0].id, originalTarget = edit.clips[0].id
    edit.dragFocus(id: id, edge: .trailing, delta: 100)
    #expect(edit.focuses[0].timelineStart == 1 && edit.focuses[0].duration == 11)
    #expect(edit.focuses[0].followsTimeline == true && edit.duration == 12)
    edit.dragFocus(id: id, edge: .trailing, delta: -9)
    #expect(edit.focuses[0].duration == 2 && edit.focuses[0].targetClipID == nil)
    let beforeMovingMedia = edit.focuses[0]
    edit.dragMedia(.screen, id: originalTarget, edge: .body, delta: 1, sourceDuration: 12)
    edit.constrainTimelineFocuses()
    #expect(edit.focuses[0] == beforeMovingMedia)
    try edit.validate(sourceDuration: 12)
}

@Test func smartFollowingInsideItsClipKeepsItsAssociationAndTrimmedAnimationPhase() throws {
    var edit = VideoEdit(duration: 8)
    edit.clips[0].timelineStart = 0
    var focus = FocusSegment(start: 1, duration: 6, x: 0.3, y: 0.5)
    focus.timelineStart = 1; focus.targetClipID = edit.clips[0].id; focus.followsTimeline = true
    edit.focuses = [focus]
    edit.constrainTimelineFocuses()
    #expect(edit.focuses[0] == focus)

    edit.dragMedia(.screen, id: edit.clips[0].id, edge: .body, delta: 2, sourceDuration: 8)
    edit.constrainTimelineFocuses()
    #expect(edit.focuses[0].timelineStart == 3 && edit.focuses[0].targetClipID == edit.clips[0].id)
    edit.clips[0].duration = 4
    edit.constrainTimelineFocuses()
    #expect(edit.focuses[0].timelineStart == 3 && edit.focuses[0].duration == 3)
    #expect(edit.focuses[0].targetClipID == edit.clips[0].id && edit.focuses[0].followsTimeline == true)
    #expect(edit.focuses[0].transitionOffset == 0 && edit.focuses[0].transitionDuration == 6)
    let normalized = edit
    edit.constrainTimelineFocuses()
    #expect(edit == normalized)
    try edit.validate(sourceDuration: 8)
}

@Test(arguments: [false, true])
func crossingClipsRespectsAnExplicitFixedCameraChoice(loading: Bool) throws {
    var edit = crossClipFocusFixture()
    edit.focuses[0].followsTimeline = false
    edit.focuses[0].path = nil; edit.focuses[0].sampledPath = nil
    let id = edit.focuses[0].id
    if loading {
        edit.focuses[0].duration = 8
        edit.focuses[0].transitionDuration = 8
        edit = try JSONDecoder().decode(VideoEdit.self, from: JSONEncoder().encode(edit))
        edit.constrainTimelineFocuses()
    } else {
        edit.dragFocus(id: id, edge: .trailing, delta: 6)
    }
    let focus = edit.focuses[0]
    #expect(focus.targetClipID == nil && focus.followsTimeline == false)
    #expect(focus.timelineStart == 1 && focus.duration == 8)
    #expect(focus.x == 0.3 && focus.y == 0.5 && focus.scale == 1.8)
    #expect(focus.path == nil && focus.sampledPath == nil)
    #expect(focus.transitionOffset == nil && focus.transitionDuration == nil)
    edit.constrainTimelineFocuses()
    #expect(edit.focuses[0] == focus)
    try edit.validate(sourceDuration: 12)
}

@Test func focusCanSpanAnInternalScreenGapButCannotUseAudioToExtendPastScreens() throws {
    var first = VideoClip(sourceStart: 0, duration: 2); first.timelineStart = 0
    var second = VideoClip(sourceStart: 2, duration: 2); second.timelineStart = 6
    var audio = VideoClip(sourceStart: 0, duration: 4); audio.timelineStart = 16
    var edit = VideoEdit(duration: 0); edit.clips = [first, second]; edit.systemClips = [audio]
    var focus = FocusSegment(start: 1, duration: 1, x: 0.5, y: 0.5)
    focus.timelineStart = 1; focus.targetClipID = first.id; edit.focuses = [focus]
    edit.dragFocus(id: focus.id, edge: .trailing, delta: 100)
    #expect(edit.focuses[0].timelineStart == 1 && edit.focuses[0].duration == 7)
    #expect(edit.focuses[0].followsTimeline == true && edit.focuses[0].targetClipID == nil)
    #expect(edit.sourceTime(at: 3) == nil && SceneEvaluator.focus(edit: edit, time: 3).scale == 1)
    #expect(edit.duration == 20)
    try edit.validate(sourceDuration: 4)
}

@Test func loadingALegacyCrossClipFocusKeepsItsFullRangeAndEnablesSmartFollowing() throws {
    var edit = crossClipFocusFixture()
    edit.focuses[0].duration = 8
    edit.focuses[0].transitionDuration = 10
    edit.focuses[0].transitionOffset = 1
    let data = try JSONEncoder().encode(edit)
    var loaded = try JSONDecoder().decode(VideoEdit.self, from: data)
    #expect(loaded.focuses[0].followsTimeline == nil)
    loaded.constrainTimelineFocuses()
    #expect(loaded.focuses[0].timelineStart == 1 && loaded.focuses[0].duration == 8)
    #expect(loaded.focuses[0].targetClipID == nil && loaded.focuses[0].followsTimeline == true)
    #expect(loaded.focuses[0].path == nil && loaded.focuses[0].sampledPath == nil)
    #expect(loaded.focuses[0].transitionDuration == nil && loaded.focuses[0].transitionOffset == nil)
    let normalized = loaded
    loaded.constrainTimelineFocuses()
    #expect(loaded == normalized)
    let roundTripped = try JSONDecoder().decode(VideoEdit.self, from: JSONEncoder().encode(loaded))
    #expect(roundTripped == loaded && roundTripped.focuses[0].followsTimeline == true)
    try loaded.validate(sourceDuration: 12)
}

@Test func deletingTheTargetPreservesFocusWhereOtherScreenContentRemains() throws {
    var first = VideoClip(sourceStart: 0, duration: 4); first.timelineStart = 0
    var second = VideoClip(sourceStart: 4, duration: 4); second.timelineStart = 3
    var edit = VideoEdit(duration: 0); edit.clips = [first, second]
    var focus = FocusSegment(start: 2, duration: 2, x: 0.5, y: 0.5)
    focus.timelineStart = 2; focus.targetClipID = first.id; edit.focuses = [focus]
    edit.clips.removeAll { $0.id == first.id }
    edit.constrainTimelineFocuses()
    #expect(edit.focuses[0].timelineStart == 3 && edit.focuses[0].duration == 1)
    #expect(edit.focuses[0].targetClipID == nil && edit.focuses[0].followsTimeline == true)
    try edit.validate(sourceDuration: 8)
    var audio = VideoClip(sourceStart: 0, duration: 4); audio.timelineStart = 0
    edit.clips = []; edit.systemClips = [audio]
    #expect(edit.focusBounds(for: focus.id) == nil)
    edit.constrainTimelineFocuses()
    #expect(edit.focuses.isEmpty && edit.duration == 4)
    try edit.validate(sourceDuration: 8)
}

@Test func timelineScopedFocusIsStableWhenClipsAreDuplicatedReorderedOrSplit() throws {
    var edit = crossClipFocusFixture()
    let id = edit.focuses[0].id
    edit.dragFocus(id: id, edge: .trailing, delta: 6)
    let original = edit.focuses[0]
    var copy = edit.clips[0]; copy.id = UUID(); copy.timelineStart = 4
    edit.clips.append(copy); edit.moveLayer(copy.id, before: edit.clips[1].id)
    #expect(edit.sourceTime(at: 5) == 1)
    edit.constrainTimelineFocuses()
    #expect(edit.focuses[0] == original)
    let split = edit.splitMedia(.screen, id: copy.id, at: 6)
    #expect(split != nil && edit.focuses == [original])
    edit.constrainTimelineFocuses()
    #expect(edit.focuses == [original])
    try edit.validate(sourceDuration: 12)
}

@Test func legacySourceFocusKeepsItsSourceTimeAndPhaseWhenExpanded() throws {
    var clip = VideoClip(sourceStart: 100, duration: 2); clip.timelineStart = 0
    var edit = VideoEdit(duration: 0); edit.clips = [clip]
    var focus = FocusSegment(start: 99, duration: 3, x: 0.3, y: 0.5)
    focus.path = [FocusKeyframe(time: 0, x: 0.3, y: 0.5, scale: 1.8, move: 0),
                  FocusKeyframe(time: 1, x: 0.5, y: 0.5, scale: 1.8, move: 1)]
    edit.focuses = [focus]
    let expected = SceneEvaluator.focus(edit: edit, time: 1.5)
    #expect(edit.focusBounds(for: focus.id) == 100...102)
    edit.prepareLayerEditing(camera: false, system: false, microphone: false)
    #expect(edit.focuses[0].timelineStart == 0 && edit.focuses[0].duration == 2)
    #expect(edit.focuses[0].targetClipID == clip.id && edit.focuses[0].followsTimeline == nil)
    #expect(edit.focuses[0].transitionOffset == 1 && edit.focuses[0].transitionDuration == 3)
    #expect(SceneEvaluator.focus(edit: edit, time: 1.5) == expected)
    try edit.validate(sourceDuration: 102)
}

private func crossClipFocusFixture() -> VideoEdit {
    var edit = VideoEdit(duration: 0)
    edit.clips = [0.0, 4, 8].map { start in
        var clip = VideoClip(sourceStart: start, duration: 4); clip.timelineStart = start; return clip
    }
    edit.prepareLayerEditing(camera: false, system: false, microphone: false)
    var focus = FocusSegment(start: 1, duration: 2, x: 0.3, y: 0.5, automatic: true)
    focus.timelineStart = 1; focus.targetClipID = edit.clips[0].id
    focus.path = [FocusKeyframe(time: 0, x: 0.3, y: 0.5, scale: 1.8, move: 0),
                  FocusKeyframe(time: 1, x: 0.5, y: 0.5, scale: 1.8, move: 1)]
    focus.sampledPath = true
    focus.transitionOffset = 0; focus.transitionDuration = 2
    edit.focuses = [focus]
    return edit
}

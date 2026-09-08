import Foundation
import Testing
@testable import EditingCore

@Test func movingOneFocusAppearanceAcrossCutKeepsOtherAppearanceAndPhase() throws {
    var edit = VideoEdit(duration: 8)
    edit.clips = [VideoClip(sourceStart: 0, duration: 2), VideoClip(sourceStart: 6, duration: 2), VideoClip(sourceStart: 6, duration: 2)]
    let focus = FocusSegment(start: 5.8, duration: 1.7, x: 0.6, y: 0.4, automatic: true)
    edit.focuses = [focus]
    let spans = edit.focusSpans()
    #expect(spans.count == 2)
    #expect(spans[0].start == 2 && spans[1].start == 4)
    let untouched = SceneEvaluator.focus(edit: edit, time: 4.1)
    edit.materializeFocus(spans[0])
    edit.dragFocus(id: focus.id, edge: .body, delta: -1)
    try edit.validate(sourceDuration: 8)
    let moved = try #require(edit.focuses.first { $0.id == focus.id })
    #expect(moved.timelineStart == 1 && !moved.automatic)
    #expect(SceneEvaluator.focus(edit: edit, time: 1.5).scale == 1.8)
    #expect(SceneEvaluator.focus(edit: edit, time: 4.1) == untouched)
    edit.automaticFocus = false
    #expect(SceneEvaluator.focus(edit: edit, time: 1.5).scale == 1.8)
    #expect(SceneEvaluator.focus(edit: edit, time: 4.1).scale == 1)
}

@Test func focusResizeClampsAndTimelineShorteningCanBeUndone() throws {
    var edit = VideoEdit(duration: 6)
    var focus = FocusSegment(start: 1, duration: 2, x: 0.5, y: 0.5)
    focus.timelineStart = 1; edit.focuses = [focus]
    edit.dragFocus(id: focus.id, edge: .leading, delta: -10)
    #expect(edit.focuses[0].timelineStart == 0 && edit.focuses[0].duration == 3)
    edit.dragFocus(id: focus.id, edge: .trailing, delta: 20)
    #expect(edit.focuses[0].duration == 6 && edit.duration == 6)
    try edit.validate(sourceDuration: 6)
    let old = edit
    var history = EditHistory(); history.record(old)
    edit.clips[0].duration = 2; edit.constrainTimelineFocuses()
    #expect(edit.focuses[0].duration == 2 && edit.duration == 2)
    try edit.validate(sourceDuration: 6)
    let restored = history.undo(current: edit)
    edit = try #require(restored)
    #expect(edit == old)
    edit.dragFocus(id: focus.id, edge: .trailing, delta: -100)
    #expect(abs(edit.focuses[0].duration - 1.0 / 30) < 1e-10)
    try edit.validate(sourceDuration: 6)
    edit.focuses[0].transitionOffset = 0.3
    #expect(throws: EditError.self) { try edit.validate(sourceDuration: 6) }
}

@Test(arguments: [-0.01, -0.2, -1.1, -2.95, -100.0])
func trailingFocusTrimKeepsStartAndDropsOutOfRangePathWithoutRollback(delta: Double) throws {
    var edit = VideoEdit(duration: 10)
    var focus = FocusSegment(start: 1, duration: 7, x: 0.3, y: 0.5, automatic: true)
    focus.path = (0...210).map { step in
        FocusKeyframe(time: Double(step) / 30, x: 0.3 + Double(step) / 1050, y: 0.5, scale: 1.8, move: 0)
    }
    focus.sampledPath = true
    edit.focuses = [focus]
    edit.prepareLayerEditing(camera: false, system: false, microphone: false)
    let splitResult = edit.splitMedia(.screen, id: edit.clips[0].id, at: 5)
    let tail = try #require(splitResult)
    let target = try #require(edit.focuses.first { $0.targetClipID == tail })
    #expect(target.transitionOffset == 4 && target.duration == 3)
    edit.dragFocus(id: target.id, edge: .trailing, delta: delta)
    let trimmed = try #require(edit.focuses.first { $0.id == target.id })
    #expect(trimmed.timelineStart == target.timelineStart)
    #expect(abs(trimmed.duration - max(1.0 / 30, 3 + delta)) < 1e-10)
    #expect(trimmed.transitionOffset == nil && trimmed.transitionDuration == nil)
    #expect(trimmed.path?.allSatisfy { $0.time <= trimmed.duration + 0.001 } ?? true)
    try edit.validate(sourceDuration: 10)
    #expect(try JSONDecoder().decode(VideoEdit.self, from: JSONEncoder().encode(edit)) == edit)
}

@Test func focusTimingControlsUseTheSamePathSafeResizeForLegacySourceFocus() throws {
    var edit = VideoEdit(duration: 10)
    var focus = FocusSegment(start: 1, duration: 8, x: 0.3, y: 0.5, automatic: true)
    focus.path = [FocusKeyframe(time: 0, x: 0.3, y: 0.5, scale: 1.8, move: 0),
                  FocusKeyframe(time: 7, x: 0.6, y: 0.5, scale: 1.8, move: 1)]
    edit.focuses = [focus]
    var previousPanelBehavior = edit
    previousPanelBehavior.focuses[0].duration = 3
    #expect(throws: EditError.self) { try previousPanelBehavior.validate(sourceDuration: 10) }

    edit.dragFocus(id: focus.id, edge: .trailing, delta: -5)
    edit.dragFocus(id: focus.id, edge: .body, delta: 1)
    #expect(edit.focuses[0].start == 2 && edit.focuses[0].duration == 3)
    #expect(edit.focuses[0].timelineStart == nil)
    #expect(edit.focuses[0].path == nil && !edit.focuses[0].automatic)
    try edit.validate(sourceDuration: 10)
}

import Foundation
import Testing
@testable import EditingCore

@Test func splitDeleteAndTrimKeepOriginalTimeMapping() throws {
    var edit = VideoEdit(duration: 12)
    let first = edit.split(at: 4), second = edit.split(at: 8)
    #expect(first && second)
    edit.clips.remove(at: 1)
    #expect(edit.duration == 8)
    #expect(edit.sourceTime(at: 4.5) == 8.5)
    edit.trim(id: edit.clips[1].id, leading: 1, trailing: 1)
    #expect(edit.duration == 6)
    #expect(edit.sourceTime(at: 4.5) == 9.5)
    try edit.validate(sourceDuration: 12)
    let head = edit.split(at: 0), tail = edit.split(at: edit.duration)
    #expect(!head && !tail)
}

@Test func focusStaysAlignedAfterRemovingEarlierContent() {
    var edit = VideoEdit(duration: 10)
    edit.focuses = [FocusSegment(start: 6, duration: 2, x: 0.8, y: 0.2)]
    _ = edit.split(at: 4); edit.clips.removeFirst()
    #expect(SceneEvaluator.focus(edit: edit, time: 2.5).scale > 1.7)
    #expect(SceneEvaluator.focus(edit: edit, time: 0).scale == 1)
    let value = SceneEvaluator.focus(edit: edit, time: 2.5)
    #expect(value.x <= 1 - 0.5 / value.scale)
    #expect(value.y >= 0.5 / value.scale)
}

@Test func automaticFocusMergesNearbyClicksAndManualOverrides() {
    let events = [PointerSample(time: 2, x: 0.5, y: 0.5, kind: .click), PointerSample(time: 2.3, x: 0.52, y: 0.5, kind: .click), PointerSample(time: 2.4, x: 0.9, y: 0.1, kind: .click)]
    var edit = VideoEdit(duration: 10)
    edit.focuses = AutoFocus.generate(events: events, duration: 10)
    #expect(edit.focuses.count == 1)
    edit.automaticFocus = false
    #expect(SceneEvaluator.focus(edit: edit, time: 2.5).scale == 1)
    edit.focuses.append(FocusSegment(start: 2, duration: 2, x: 0.5, y: 0.5, scale: 2.4))
    #expect(SceneEvaluator.focus(edit: edit, time: 2.5).scale == 2.4)
}

@Test func undoRedoRestoresFullSnapshotAndNewEditClearsRedo() throws {
    var history = EditHistory(), edit = VideoEdit(duration: 8)
    let original = edit
    history.record(edit); _ = edit.split(at: 4); edit.layout.padding = 80
    let changed = edit
    let undone = history.undo(current: edit); edit = try #require(undone); #expect(edit == original)
    let redone = history.redo(current: edit); edit = try #require(redone); #expect(edit == changed)
    let again = history.undo(current: edit); edit = try #require(again); history.record(edit)
    #expect(!history.canRedo)
}

@Test func invalidEditDoesNotReachRendering() {
    var edit = VideoEdit(duration: 5)
    edit.clips[0].sourceStart = -1
    #expect(throws: EditError.self) { try edit.validate(sourceDuration: 5) }
    edit = VideoEdit(duration: 5); edit.layout.padding = .infinity
    #expect(throws: EditError.self) { try edit.validate(sourceDuration: 5) }
    edit = VideoEdit(duration: 5); edit.schemaVersion = 200
    #expect(throws: EditError.self) { try edit.validate(sourceDuration: 5) }
}

@Test func trimmedClipCanBeExtendedAfterReopening() throws {
    var edit = VideoEdit(duration: 12)
    let id = edit.clips[0].id
    edit.trim(id: id, leading: 2, trailing: 3)
    var reopened = try JSONDecoder().decode(VideoEdit.self, from: JSONEncoder().encode(edit))
    reopened.resize(id: id, sourceStart: -2, sourceEnd: 20, sourceDuration: 12)
    #expect(reopened.clips[0].sourceStart == 0 && reopened.duration == 12)
}

@Test func minimumClipDurationGuardsSplitTrimAndResize() {
    var edit = VideoEdit(duration: 10)
    let id = edit.clips[0].id
    #expect(!edit.split(at: 0.1) && !edit.split(at: 9.9))
    #expect(edit.split(at: 4) && edit.clips.count == 2)
    edit.resize(id: id, sourceStart: 0, sourceEnd: 0.01, sourceDuration: 10)
    #expect(abs(edit.clips[0].duration - VideoEdit.minimumClipDuration) < 1e-9)
    // 拖尾边越过最小长度：以起点为锚把尾边推回，而不是让片段消失。
    edit.resize(id: id, sourceStart: 3.99, sourceEnd: 4, sourceDuration: 10)
    #expect(abs(edit.clips[0].duration - VideoEdit.minimumClipDuration) < 1e-9 && abs(edit.clips[0].sourceStart - 3.99) < 1e-9)
    edit.trim(id: id, leading: 5, trailing: 5)
    #expect(edit.clips[0].duration >= VideoEdit.minimumClipDuration - 1e-9)
}

@Test func timelineTimeForSourceFollowsClipOrder() {
    var edit = VideoEdit(duration: 12)
    edit.clips = [VideoClip(sourceStart: 6, duration: 2), VideoClip(sourceStart: 1, duration: 3)]
    #expect(edit.timelineTime(forSource: 7) == 1)
    #expect(edit.timelineTime(forSource: 2.5) == 3.5)
    #expect(edit.timelineTime(forSource: 5) == nil)
    #expect(edit.timelineTime(forSource: -1) == nil)
    let end = edit.timelineTime(forSource: 4)
    #expect(end != nil && end! < 5 && end! > 4.99)
}

/// 语音处理开关：旧文件缺省关闭，编码后可还原；它换的是麦克风素材文件，所以算作素材变化。
@Test func voiceProcessingFlagDefaultsOffAndCountsAsMediaChange() throws {
    let legacy = try JSONDecoder().decode(AudioLevels.self, from: Data(#"{"system":0.7,"microphone":1}"#.utf8))
    #expect(!legacy.voiceProcessing)
    var levels = AudioLevels(); levels.voiceProcessing = true
    let restored = try JSONDecoder().decode(AudioLevels.self, from: JSONEncoder().encode(levels))
    #expect(restored.voiceProcessing)
    var edit = VideoEdit(duration: 8)
    var toggled = edit; toggled.audio.voiceProcessing = true
    #expect(!edit.hasSameMedia(as: toggled))
    edit.audio.voiceProcessing = true
    #expect(edit.hasSameMedia(as: toggled))
}


import Foundation
import Testing
@testable import EditingCore

@Test func independentLayersKeepTimeAndEffectTargetWhenReordered() throws {
    var edit = VideoEdit(duration: 8)
    _ = edit.split(at: 4)
    edit.prepareLayerEditing(camera: true, system: true, microphone: true)
    let first = edit.clips[0].id, second = edit.clips[1].id
    edit.dragMedia(.screen, id: second, edge: .body, delta: -2, sourceDuration: 8)
    #expect(edit.sourceTime(at: 3) == 5)
    edit.moveLayer(first, before: second)
    #expect(edit.sourceTime(at: 3) == 3)
    let camera = edit.cameraClips
    let audio = edit.systemClips
    edit.dragMedia(.screen, id: first, edge: .trailing, delta: 10, sourceDuration: 8)
    #expect(edit.duration == 14)
    #expect(abs((edit.sourceTime(at: 12) ?? 0) - 8) < 0.001)
    #expect(edit.cameraClips == camera && edit.systemClips == audio)
    try edit.validate(sourceDuration: 8)
    #expect(try JSONDecoder().decode(VideoEdit.self, from: JSONEncoder().encode(edit)) == edit)
}

@Test func indexPreservesInternalAndLeadingGaps() {
    var a = VideoClip(sourceStart: 0, duration: 1); a.timelineStart = 2
    var b = VideoClip(sourceStart: 3, duration: 1); b.timelineStart = 5
    let timeline = TimelineIndex(clips: [a, b])
    #expect(timeline.sourceTime(at: 0.5) == nil)
    #expect(timeline.sourceTime(at: 3.5) == nil)
    #expect(timeline.sourceTime(at: 5.5) == 3.5)
    #expect(timeline.duration == 6)
}

@Test func splittingLinkedFocusPreservesPathPhaseAndValidates() throws {
    var edit = VideoEdit(duration: 8)
    var focus = FocusSegment(start: 1, duration: 6, x: 0.3, y: 0.5)
    focus.path = [FocusKeyframe(time: 0, x: 0.3, y: 0.5, scale: 1.8, move: 0), FocusKeyframe(time: 5, x: 0.7, y: 0.5, scale: 1.8, move: 1)]
    edit.focuses = [focus]
    edit.prepareLayerEditing(camera: false, system: false, microphone: false)
    let expected = SceneEvaluator.focus(edit: edit, time: 5)
    edit.splitMedia(.screen, id: edit.clips[0].id, at: 4)
    try edit.validate(sourceDuration: 8)
    #expect(edit.focuses.count == 2)
    #expect(SceneEvaluator.focus(edit: edit, time: 5) == expected)
    let tail = try #require(edit.focuses.first { $0.timelineStart == 4 })
    edit.dragFocus(id: tail.id, edge: .trailing, delta: -1)
    try edit.validate(sourceDuration: 8)
}

@Test func repeatedSplitsKeepTheirRowsAdjacentAfterReordering() throws {
    var edit = VideoEdit(duration: 12)
    edit.prepareLayerEditing(camera: false, system: true, microphone: false)
    let original = edit.clips[0].id
    let audio = try #require(edit.systemClips?.first?.id)
    let secondResult = edit.splitMedia(.screen, id: original, at: 4)
    let second = try #require(secondResult)
    let thirdResult = edit.splitMedia(.screen, id: second, at: 8)
    let third = try #require(thirdResult)
    #expect(edit.orderedLayerIDs == [third, second, original, audio])

    // 原始素材数组与显示行序刻意不同，分割不能按显示数组中“后一项”猜新块。
    edit.moveLayer(original, before: third)
    let fourthResult = edit.splitMedia(.screen, id: second, at: 6)
    let fourth = try #require(fourthResult)
    #expect(edit.orderedLayerIDs == [original, third, fourth, second, audio])
    #expect(edit.clips.map(\.id) == [original, second, fourth, third])
    #expect(edit.clips.first { $0.id == fourth }?.timelineStart == 6)
    #expect(edit.clips.first { $0.id == fourth }?.sourceStart == 6)
    #expect(edit.clips.first { $0.id == fourth }?.duration == 2)
    #expect(edit.sourceTime(at: 6.5) == 6.5)
    try edit.validate(sourceDuration: 12)
}

@Test(arguments: [TimelineMedia.camera, .system, .microphone])
func independentMediaSplitReturnsNewIDAndKeepsRowPosition(role: TimelineMedia) throws {
    var edit = VideoEdit(duration: 8)
    edit.prepareLayerEditing(camera: true, system: true, microphone: true)
    let original = try #require(edit.mediaClips(role).first?.id)
    edit.moveLayer(original, before: nil)
    let before = edit.orderedLayerIDs
    let newIDResult = edit.splitMedia(role, id: original, at: 4)
    let newID = try #require(newIDResult)
    #expect(edit.orderedLayerIDs == Array(before.dropLast()) + [newID, original])
    #expect(edit.mediaClips(role).first { $0.id == newID }?.timelineStart == 4)
    let snapshot = edit
    let tooShort = edit.splitMedia(role, id: original, at: 0.1)
    let nonFinite = edit.splitMedia(role, id: original, at: .infinity)
    #expect(tooShort == nil && nonFinite == nil)
    #expect(edit == snapshot)
    try edit.validate(sourceDuration: 8)
}

@Test func splitRegroupsLinkedEffectsAtOriginalRowAndPreservesEffectPriority() throws {
    var edit = VideoEdit(duration: 8)
    edit.prepareLayerEditing(camera: true, system: true, microphone: false)
    let original = edit.clips[0].id
    let camera = try #require(edit.cameraClips?.first?.id)
    let audio = try #require(edit.systemClips?.first?.id)
    var crossing = FocusSegment(start: 1, duration: 6, x: 0.3, y: 0.5)
    crossing.timelineStart = 1; crossing.targetClipID = original
    var head = FocusSegment(start: 1, duration: 1, x: 0.4, y: 0.5)
    head.timelineStart = 1; head.targetClipID = original
    var tail = FocusSegment(start: 5, duration: 1, x: 0.6, y: 0.5)
    tail.timelineStart = 5; tail.targetClipID = original
    edit.focuses = [crossing, head, tail]
    edit.layerOrder = [tail.id, camera, original, audio, crossing.id, head.id]
    let expected = SceneEvaluator.focus(edit: edit, time: 5.5)
    let newIDResult = edit.splitMedia(.screen, id: original, at: 4)
    let newID = try #require(newIDResult)
    let newFocus = try #require(edit.focuses.first { $0.targetClipID == newID && $0.id != tail.id })
    #expect(edit.orderedLayerIDs == [camera, tail.id, newFocus.id, newID, crossing.id, head.id, original, audio])
    #expect(SceneEvaluator.focus(edit: edit, time: 5.5) == expected)
    #expect(edit.focuses.first { $0.id == tail.id }?.targetClipID == newID)
    try edit.validate(sourceDuration: 8)
    #expect(try JSONDecoder().decode(VideoEdit.self, from: JSONEncoder().encode(edit)) == edit)
}

@Test func regeneratedFocusRowsAttachToTargetsWithoutResettingExistingOrder() throws {
    var edit = VideoEdit(duration: 8)
    _ = edit.split(at: 4)
    edit.prepareLayerEditing(camera: true, system: true, microphone: false)
    let first = edit.clips[0].id, second = edit.clips[1].id
    edit.moveLayer(first, before: second)
    let previousOrder = edit.orderedLayerIDs
    var manual = FocusSegment(start: 1, duration: 1, x: 0.4, y: 0.5)
    manual.timelineStart = 1; manual.targetClipID = first
    edit.focuses = [manual]
    edit.moveLayer(manual.id, before: nil)
    let automatic = FocusSegment(start: 2, duration: 4, x: 0.5, y: 0.5, automatic: true)
    edit.focuses.append(automatic)
    edit.prepareLayerEditing(camera: true, system: true, microphone: false)
    let firstFocus = try #require(edit.focuses.first { $0.automatic && $0.targetClipID == first })
    let secondFocus = try #require(edit.focuses.first { $0.automatic && $0.targetClipID == second })
    var expected = previousOrder
    expected.insert(firstFocus.id, at: try #require(expected.firstIndex(of: first)))
    expected.insert(secondFocus.id, at: try #require(expected.firstIndex(of: second)))
    expected.append(manual.id)
    #expect(edit.orderedLayerIDs == expected)
    let materialized = edit
    edit.prepareLayerEditing(camera: true, system: true, microphone: false)
    #expect(edit == materialized)
    try edit.validate(sourceDuration: 8)
}

/// 默认行序：镜头与录制画面在上，摄像头行紧贴在声音轨上方，最后是系统声音、麦克风。
@Test func defaultLayerOrderPutsCameraRowJustAboveAudio() throws {
    var edit = VideoEdit(duration: 8)
    edit.prepareLayerEditing(camera: true, system: true, microphone: true)
    let screen = edit.clips[0].id
    let camera = try #require(edit.cameraClips?.first?.id)
    let system = try #require(edit.systemClips?.first?.id), microphone = try #require(edit.microphoneClips?.first?.id)
    #expect(edit.orderedLayerIDs == [screen, camera, system, microphone])
}

/// 老工程仍是旧默认（摄像头行在最顶端）时迁到声音轨上方；手动排过或与他行合并的顺序不动。
@Test func legacyCameraFirstOrderMigratesUnlessArrangedManually() throws {
    var edit = VideoEdit(duration: 8)
    edit.prepareLayerEditing(camera: true, system: true, microphone: false)
    let screen = edit.clips[0].id
    let camera = try #require(edit.cameraClips?.first?.id), audio = try #require(edit.systemClips?.first?.id)
    edit.layerOrder = [camera, screen, audio]
    edit.prepareLayerEditing(camera: true, system: true, microphone: false)
    #expect(edit.orderedLayerIDs == [screen, camera, audio])
    edit.layerOrder = [screen, audio, camera]
    edit.prepareLayerEditing(camera: true, system: true, microphone: false)
    #expect(edit.orderedLayerIDs == [screen, audio, camera], "手动排到最下面的保留")
    edit.layerOrder = [camera, screen, audio]; edit.rowGroups = [[camera, screen]]
    edit.prepareLayerEditing(camera: true, system: true, microphone: false)
    #expect(edit.orderedLayerIDs == [camera, screen, audio], "与画面同行的不迁")
}


import Foundation
import Testing
@testable import EditingCore

@Test func timelineRowsPersistAcrossMediaKindsWithoutChangingTimeOrSource() throws {
    var edit = rowFixture()
    let screen = edit.clips[0].id, camera = try #require(edit.cameraClips?.first?.id)
    let audio = try #require(edit.systemClips?.first?.id), focus = try #require(edit.focuses.first?.id)
    let ranges = edit.timelineBlockRanges, sourceStarts = edit.clips.map(\.sourceStart)
    let cameraJoined = edit.placeBlock(camera, inRowContaining: screen)
    let audioJoined = edit.placeBlock(audio, inRowContaining: camera)
    let focusJoined = edit.placeBlock(focus, inRowContaining: screen)
    #expect(cameraJoined && audioJoined && focusJoined)
    // 三段录制默认就同一行（同类不重叠），再把摄像头、声音、聚焦拖进来之后全在一行。
    #expect(edit.timelineRows.count == 1)
    let shared = try #require(edit.timelineRows.first { $0.contains(screen) })
    #expect(Set(shared) == Set(edit.orderedLayerIDs))
    #expect(Set(shared).isSuperset(of: [screen, camera, audio, focus]))
    #expect(edit.rowGroups?.count == 1 && edit.rowGroups?.first == shared)
    #expect(edit.orderedLayerIDs == edit.timelineRows.flatMap { $0 })
    #expect(edit.timelineBlockRanges == ranges && edit.clips.map(\.sourceStart) == sourceStarts)
    try edit.validate(sourceDuration: 24)
    #expect(try JSONDecoder().decode(VideoEdit.self, from: JSONEncoder().encode(edit)) == edit)
}

@Test func overlappingRowPlacementIsAtomicButTouchingEndpointsAreAllowed() throws {
    var edit = rowFixture()
    let first = edit.clips[0].id, second = edit.clips[1].id
    edit.clips[1].timelineStart = 1
    let before = edit
    #expect(!edit.canPlaceBlock(second, inRowContaining: first))
    let rejected = edit.placeBlock(second, inRowContaining: first)
    #expect(!rejected && edit == before)
    let missing = edit.placeBlock(UUID(), inRowContaining: first)
    #expect(!missing && edit == before)
    edit.clips[1].timelineStart = 2
    let joined = edit.placeBlock(second, inRowContaining: first)
    #expect(joined)
    let row = try #require(edit.timelineRows.first { $0.contains(first) })
    #expect(row.contains(second))
}

@Test func blockCanLeaveSharedRowAndWholeRowMovesAsOneUnit() throws {
    var edit = rowFixture()
    let a = edit.clips[0].id
    let camera = try #require(edit.cameraClips?.first?.id), audio = try #require(edit.systemClips?.first?.id)
    _ = edit.placeBlock(camera, inRowContaining: a)
    let ranges = edit.timelineBlockRanges
    let members = try #require(edit.timelineRows.first { $0.contains(a) })
    #expect(members.contains(camera))
    edit.moveTimelineRow(containing: camera, before: audio)
    let rows = edit.timelineRows
    let moved = try #require(rows.firstIndex { $0.contains(a) }), target = try #require(rows.firstIndex { $0.contains(audio) })
    #expect(moved + 1 == target && rows[moved] == members)
    #expect(edit.timelineBlockRanges == ranges)
    // 拖出来自己占一行：默认是同类自动并行，所以必须留下"这一块单独成行"的显式记录，
    // 不然下一次排行又把它并回去。
    edit.placeBlock(camera, beforeRowContaining: a)
    #expect(edit.rowGroups?.contains([camera]) == true)
    let separated = edit.timelineRows
    let cameraRow = try #require(separated.firstIndex { $0.contains(camera) })
    #expect(separated[cameraRow] == [camera])
    #expect(separated.first { $0.contains(a) }?.contains(camera) == false)
    #expect(cameraRow < (separated.firstIndex { $0.contains(a) } ?? 0))
    #expect(edit.timelineBlockRanges == ranges)
}

@Test func deletedAndDuplicateRowMembersNormalizeWithoutOrphanRows() throws {
    var edit = rowFixture()
    let a = edit.clips[0].id, b = edit.clips[1].id, c = edit.clips[2].id
    let camera = try #require(edit.cameraClips?.first?.id)
    // 把摄像头拖进录制那一行：这一下才会写出显式行（三段录制本来就自动同行）。
    _ = edit.placeBlock(camera, inRowContaining: a)
    edit.setMediaClips(.screen, edit.clips.filter { $0.id != b })
    #expect(edit.rowGroups?.count == 1 && Set(edit.rowGroups?.first ?? []) == Set([a, c, camera]))
    edit.clips.removeAll { $0.id == c }
    edit.normalizeTimelineRows()
    #expect(Set(edit.rowGroups?.first ?? []) == Set([a, camera]))
    edit.rowGroups = [[UUID(), a, a, camera], [camera, UUID()]]
    edit.normalizeTimelineRows()
    #expect(edit.rowGroups?.count == 1 && Set(edit.rowGroups?.first ?? []) == Set([a, camera]))
    #expect(edit.timelineRows.flatMap { $0 }.count == Set(edit.orderedLayerIDs).count)
}

@Test func sharedClipSplitKeepsBothHalvesInRowAndEffectsAboveWholeRow() throws {
    var edit = VideoEdit(duration: 0)
    var a = VideoClip(sourceStart: 0, duration: 4); a.timelineStart = 0
    var b = VideoClip(sourceStart: 6, duration: 4); b.timelineStart = 6
    edit.clips = [a, b]; edit.layerOrder = [b.id, a.id]; edit.schemaVersion = 6
    var focus = FocusSegment(start: 1, duration: 2, x: 0.4, y: 0.5)
    focus.timelineStart = 1; focus.targetClipID = a.id
    edit.focuses = [focus]; edit.moveLayer(focus.id, before: a.id)
    _ = edit.placeBlock(a.id, inRowContaining: b.id)
    let split = edit.splitMedia(.screen, id: a.id, at: 2)
    let tail = try #require(split)
    let rows = edit.timelineRows
    let videoRow = try #require(rows.firstIndex { $0.contains(a.id) })
    #expect(Set(rows[videoRow]) == Set([a.id, b.id, tail]))
    #expect(edit.focuses.count == 2)
    // 切开的两个镜头首尾相接，默认并到同一行，且整行压在录制那一行上面。
    var effectRows = Set<Int>()
    for effect in edit.focuses { effectRows.insert(try #require(rows.firstIndex { $0.contains(effect.id) })) }
    #expect(effectRows.count == 1)
    let effectRow = try #require(effectRows.first)
    #expect(effectRow < videoRow && rows[effectRow].count == 2)
    #expect(edit.clips.first { $0.id == tail }?.timelineStart == 2)
    #expect(edit.clips.first { $0.id == tail }?.sourceStart == 2)
    #expect(edit.sourceTime(at: 3) == 3)
    try edit.validate(sourceDuration: 10)
}

/// 切一刀不该把一条轨劈成两行：两半首尾相接、同类，默认落回同一行。
@Test func splittingAClipKeepsBothHalvesOnTheSameRow() throws {
    var edit = rowFixture()
    let a = edit.clips[0].id, b = edit.clips[1].id, c = edit.clips[2].id
    let before = try #require(edit.timelineRows.first { $0.contains(a) })
    #expect(Set(before) == Set([a, b, c]), "三段录制本来就该在一行")
    let result = edit.splitMedia(.screen, id: a, at: 1)
    let tail = try #require(result)
    let row = try #require(edit.timelineRows.first { $0.contains(a) })
    #expect(Set(row) == Set([a, tail, b, c]), "切完之后行变成了 \(edit.timelineRows.count) 行")
    // 切一刀不该把自动排出来的行写死成显式行，否则以后新加的同类块再也并不进来。
    #expect(edit.rowGroups == nil)
}

@Test func rowDraggingStopsAtNeighborsWithoutChangingUnsharedBlocks() {
    var edit = rowFixture()
    let a = edit.clips[0].id, b = edit.clips[1].id, c = edit.clips[2].id
    _ = edit.placeBlock(b, inRowContaining: a); _ = edit.placeBlock(c, inRowContaining: a)
    #expect(edit.rowDragDelta(for: b, edge: .body, proposed: -100) == -2)
    #expect(edit.rowDragDelta(for: b, edge: .body, proposed: 100) == 2)
    #expect(edit.rowDragDelta(for: b, edge: .leading, proposed: -100) == -2)
    #expect(edit.rowDragDelta(for: b, edge: .trailing, proposed: 100) == 2)
    #expect(edit.rowDragDelta(for: b, edge: .body, proposed: 1.25) == 1.25)
    #expect(edit.rowDragDelta(for: b, edge: .body, proposed: .nan) == 0)
    #expect(edit.rowDragDelta(for: edit.focuses[0].id, edge: .body, proposed: 100) == 100)
}

@Test func screenAndLinkedFocusesShareTheStrictestStationaryRowBoundary() throws {
    var edit = VideoEdit(duration: 10)
    edit.prepareLayerEditing(camera: false, system: false, microphone: false)
    let screen = edit.clips[0].id
    var first = FocusSegment(start: 1, duration: 1, x: 0.4, y: 0.5)
    var second = FocusSegment(start: 2, duration: 0.5, x: 0.5, y: 0.5)
    var third = FocusSegment(start: 7, duration: 1, x: 0.6, y: 0.5)
    first.timelineStart = 1; first.targetClipID = screen
    second.timelineStart = 2; second.targetClipID = screen
    third.timelineStart = 7; third.targetClipID = screen
    edit.focuses = [first, second, third]
    var near = VideoClip(sourceStart: 4, duration: 1); near.timelineStart = 4
    var far = VideoClip(sourceStart: 9, duration: 1); far.timelineStart = 9
    edit.systemClips = [near, far]
    _ = edit.placeBlock(first.id, inRowContaining: near.id)
    _ = edit.placeBlock(second.id, inRowContaining: first.id)
    _ = edit.placeBlock(third.id, inRowContaining: far.id)
    let allowed = edit.rowDragDelta(for: screen, edge: .body, proposed: 6)
    #expect(allowed == 1, "第三个聚焦距静止声音块仅一秒；前两个跟随聚焦彼此不能阻挡")
    let originalAudio = edit.systemClips
    edit.dragMedia(.screen, id: screen, edge: .body, delta: allowed, sourceDuration: 10)
    #expect(edit.clips[0].timelineStart == 1)
    #expect(edit.focuses.map(\.timelineStart) == [2, 3, 8])
    #expect(edit.systemClips == originalAudio)
    for focus in edit.focuses { #expect(edit.canPlaceBlock(focus.id, inRowContaining: focus.id)) }
    try edit.validate(sourceDuration: 10)
}

@Test func leavingScreenRowStillConstrainsLinkedFocusRows() throws {
    var edit = VideoEdit(duration: 10)
    edit.prepareLayerEditing(camera: false, system: false, microphone: false)
    let screen = edit.clips[0].id
    var next = VideoClip(sourceStart: 11, duration: 1); next.timelineStart = 11
    edit.clips.append(next)
    var focus = FocusSegment(start: 1, duration: 1, x: 0.5, y: 0.5)
    focus.timelineStart = 1; focus.targetClipID = screen
    edit.focuses = [focus]
    var sound = VideoClip(sourceStart: 6, duration: 1); sound.timelineStart = 6
    edit.systemClips = [sound]
    _ = edit.placeBlock(next.id, inRowContaining: screen)
    _ = edit.placeBlock(focus.id, inRowContaining: sound.id)
    #expect(edit.rowDragDelta(for: screen, edge: .body, proposed: 8) == 1)
    #expect(edit.rowDragDelta(for: screen, edge: .body, proposed: 8, leavingRow: true) == 4)
    #expect(edit.rowDragDelta(for: focus.id, edge: .body, proposed: 8, leavingRow: true) == 8, "独立拖聚焦离行时不保留原行障碍")
    try edit.validate(sourceDuration: 12)
}

@Test func legacyRowsRemainSingletonsAndFirstGroupingPreservesSourceMapping() throws {
    var edit = VideoEdit(duration: 0)
    edit.clips = [VideoClip(sourceStart: 0, duration: 4), VideoClip(sourceStart: 8, duration: 2)]
    let original = edit
    // 老工程的连续拼接：两块首尾相接、同类，默认就在一行，而且没动过任何数据。
    #expect(edit.timelineRows == [edit.clips.map(\.id)] && edit == original)
    let json = try JSONEncoder().encode(edit)
    #expect(!(String(data: json, encoding: .utf8) ?? "").contains("rowGroups"))
    #expect(try JSONDecoder().decode(VideoEdit.self, from: json).timelineRows == edit.timelineRows)
    let expected = edit.sourceTime(at: 4.5)
    let result = edit.placeBlock(edit.clips[1].id, inRowContaining: edit.clips[0].id)
    // 本来就同行，这一下什么都不用做：不写分组，也不把连续拼接冻成显式起点。
    #expect(result && edit.timelineRows.count == 1 && edit.rowGroups == nil)
    #expect(edit.clips.map(\.timelineStart) == [nil, nil] && edit.sourceTime(at: 4.5) == expected)
    #expect(edit.cameraClips == nil && edit.systemClips == nil && edit.microphoneClips == nil)
    try edit.validate(sourceDuration: 10)
}

@Test func hundredThousandBlocksResolveRowsWithStableMemberPriority() {
    var edit = VideoEdit(duration: 0)
    edit.clips = (0..<100_000).map { number in
        var clip = VideoClip(sourceStart: Double(number), duration: 1)
        clip.timelineStart = Double(number); return clip
    }
    let ids = edit.clips.map(\.id)
    edit.layerOrder = ids
    edit.rowGroups = stride(from: 0, to: ids.count, by: 2).map { [ids[$0 + 1], ids[$0]] }
    let rows = edit.timelineRows
    #expect(rows.count == 50_000 && rows.flatMap { $0 } == ids)
    edit.normalizeTimelineRows()
    #expect(edit.rowGroups == rows)
}

private func rowFixture() -> VideoEdit {
    var edit = VideoEdit(duration: 0)
    edit.schemaVersion = 6
    edit.clips = [0.0, 4, 8].map { start in
        var clip = VideoClip(sourceStart: start, duration: 2); clip.timelineStart = start; return clip
    }
    var camera = VideoClip(sourceStart: 12, duration: 2); camera.timelineStart = 12
    var audio = VideoClip(sourceStart: 16, duration: 2); audio.timelineStart = 16
    // 聚焦落在第一、二段录制之间的空档里，可以和三段录制、摄像头、声音同处一行。
    var focus = FocusSegment(start: 2.5, duration: 1, x: 0.5, y: 0.5)
    focus.timelineStart = 2.5
    edit.cameraClips = [camera]; edit.systemClips = [audio]; edit.microphoneClips = []
    edit.focuses = [focus]
    edit.layerOrder = [edit.clips[0].id, edit.clips[1].id, edit.clips[2].id, camera.id, focus.id, audio.id]
    return edit
}

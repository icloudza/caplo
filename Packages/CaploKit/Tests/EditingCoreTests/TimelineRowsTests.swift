import Foundation
import Testing
@testable import EditingCore

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

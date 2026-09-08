import Foundation
import Testing
@testable import EditingCore

@Test func indexedTimelinePreservesCutBoundariesAndVisibleRanges() {
    let clips = [VideoClip(sourceStart: 0, duration: 2), VideoClip(sourceStart: 7, duration: 3), VideoClip(sourceStart: 1, duration: 1)]
    let index = TimelineIndex(clips: clips)
    #expect(index.sourceTime(at: 2) == 7)
    #expect(index.sourceTime(at: 4.5) == 9.5)
    #expect(index.sourceTime(at: 6)! < 2)
    #expect(index.sourceTime(at: -1) == nil)
    #expect(index.sourceTime(at: .nan) == nil)
    #expect(index.visibleClips(in: 2..<5) == 1..<2)
    #expect(index.visibleClips(in: -1..<2) == 0..<1)
    #expect(index.visibleClips(in: 5..<20) == 2..<3)
    #expect(index.visibleClips(in: 10..<20).isEmpty)
    #expect(index.snap(2.05, tolerance: 0.1) == 2)
    #expect(index.snap(2.05, tolerance: 0.1, excluding: [1]) == nil)
    #expect(index.snap(2.05, tolerance: 0.1, extra: [2.02]) == 2.02)
    #expect(index.insertionIndex(at: 4.8) == 2)
    #expect(index.insertionIndex(at: 100) == 3)
}

@Test func longTimelineQueriesOnlyVisibleClips() {
    let clips = (0..<100_000).map { VideoClip(sourceStart: Double($0 % 10), duration: 1) }
    let index = TimelineIndex(clips: clips)
    #expect(index.visibleClips(in: 99_980.5..<99_990.5) == 99_980..<99_991)
    #expect(index.sourceTime(at: 99_987.25) == 7.25)
    #expect(index.duration == 100_000)
    #expect(TimelineTime.code(3661 + 29.0 / 30) == "01:01:01:29")
    #expect(abs(TimelineTime.quantized(0.051) - 2.0 / 30) < 1e-10)
}

@Test func groupReorderAndDuplicateKeepSourceRangesAndUniqueIDs() throws {
    var edit = VideoEdit(duration: 8)
    _ = edit.split(at: 2); _ = edit.split(at: 4); _ = edit.split(at: 6)
    let original = edit.clips
    edit.moveClips([original[0].id, original[2].id], before: 4)
    #expect(edit.clips.map(\.sourceStart) == [2, 6, 0, 4])
    let copies = edit.duplicateClips([original[0].id, original[2].id])
    #expect(copies.count == 2)
    #expect(edit.clips.map(\.sourceStart) == [2, 6, 0, 4, 0, 4])
    #expect(edit.duration == 12)
    try edit.validate(sourceDuration: 8)
    let before = edit
    edit.moveClips(copies, before: 6)
    #expect(edit == before)
}

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


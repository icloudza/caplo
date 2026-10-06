import Foundation
import Testing
@testable import EditingCore

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


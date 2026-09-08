import Foundation
import Testing
@testable import EditingCore

@Test func renamingBlocksPersistsAndBlankRestoresDefault() throws {
    var edit = VideoEdit(duration: 4)
    let clipID = try #require(edit.clips.first?.id)
    edit.systemClips = [VideoClip(sourceStart: 0, duration: 4)]
    let systemID = try #require(edit.systemClips?.first?.id)
    var focus = FocusSegment(start: 1, duration: 1, x: 0.5, y: 0.5)
    focus.timelineStart = 1
    edit.focuses.append(focus)

    edit.renameBlock(clipID, title: "  开场  ")
    edit.renameBlock(systemID, title: "背景音乐")
    edit.renameBlock(focus.id, title: "放大标题")
    #expect(edit.clips.first?.title == "开场")
    #expect(edit.systemClips?.first?.title == "背景音乐")
    #expect(edit.focuses.first?.title == "放大标题")
    // 面板与时间线共用的显示名：自定义名优先，清除后回到"镜头聚焦 · 倍率"。
    #expect(edit.focuses.first?.displayTitle == "放大标题")

    let data = try JSONEncoder().encode(edit)
    let decoded = try JSONDecoder().decode(VideoEdit.self, from: data)
    #expect(decoded.clips.first?.title == "开场")
    #expect(decoded.systemClips?.first?.title == "背景音乐")
    #expect(decoded.focuses.first?.title == "放大标题")

    edit.renameBlock(clipID, title: "   ")
    edit.renameBlock(focus.id, title: nil)
    #expect(edit.clips.first?.title == nil)
    #expect(edit.focuses.first?.title == nil)
    #expect(edit.focuses.first?.displayTitle == "镜头聚焦 · 1.8×")
    // 未命名的块不写入字段，旧版本与旧工程互不影响。
    let plain = try String(decoding: JSONEncoder().encode(edit.clips[0]), as: UTF8.self)
    #expect(!plain.contains("\"title\""))
    let unknown = UUID()
    let before = edit
    edit.renameBlock(unknown, title: "无人认领")
    #expect(edit == before)
}


/// 多个镜头按时间线顺序编号："镜头聚焦 1 · 1.8×""镜头聚焦 2 · 2.0×"；只有一个时不编号；自定义名优先；关掉自动镜头后重新编号。
@Test func multipleFocusesAreNumberedInTimelineOrder() {
    var edit = VideoEdit(duration: 20)
    var late = FocusSegment(start: 10, duration: 2, x: 0.5, y: 0.5, scale: 2.0); late.timelineStart = 10
    var early = FocusSegment(start: 2, duration: 2, x: 0.5, y: 0.5, scale: 1.8); early.timelineStart = 2
    edit.focuses = [late]
    #expect(edit.focusDisplayTitle(late) == "镜头聚焦 · 2.0×")
    edit.focuses = [late, early]
    #expect(edit.focusDisplayTitle(early) == "镜头聚焦 1 · 1.8×" && edit.focusDisplayTitle(late) == "镜头聚焦 2 · 2.0×")
    edit.focuses[1].title = "开场"
    #expect(edit.focusDisplayTitle(edit.focuses[1]) == "开场" && edit.focusDisplayTitle(edit.focuses[0]) == "镜头聚焦 2 · 2.0×")
    var automatic = FocusSegment(start: 5, duration: 2, x: 0.5, y: 0.5, scale: 1.8, automatic: true)
    automatic.easeIn = 0.6; automatic.easeOut = 0.7
    edit.focuses.append(automatic)
    #expect(edit.focusDisplayTitle(automatic) == "镜头聚焦 2 · 1.8×" && edit.focusDisplayTitle(late) == "镜头聚焦 3 · 2.0×")
    edit.automaticFocus = false
    #expect(edit.focusDisplayTitle(late) == "镜头聚焦 2 · 2.0×")
}

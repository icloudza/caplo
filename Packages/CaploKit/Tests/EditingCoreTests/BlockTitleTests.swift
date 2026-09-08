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

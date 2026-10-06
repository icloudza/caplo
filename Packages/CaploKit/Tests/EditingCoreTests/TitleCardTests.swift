import Foundation
import Testing
@testable import EditingCore

/// 卡片：画面轨上自带背景与文字的一段，片头 / 章节 / 片尾用。插入时后面的一切让开，卡片上没有录屏与声音，
/// 删掉之后时间轴和片段都回到插入前的样子。
private func recording(_ duration: Double) -> VideoEdit {
    var edit = VideoEdit(duration: duration)
    edit.materializeLayers()
    return edit
}

@Test func insertingACardMakesRoomAndRemovingItRejoinsTheCut() throws {
    var edit = recording(10)
    // 源域遮罩横跨插入点：它要跟着后半段画面走，不能投影到卡片上。
    edit.addMask(MaskSegment(start: 1, duration: 4, x: 0.5, y: 0.5, width: 0.3, height: 0.2))
    let inserted = edit.insertCard(at: 4, duration: 3)
    let id = try #require(inserted)
    try edit.validate(sourceDuration: 10)
    #expect(abs(edit.duration - 13) < 0.001, "成片是 \(edit.duration) 秒")
    let card = try #require(edit.clips.first { $0.id == id })
    #expect(card.timelineStart == 4 && abs(card.duration - 3) < 0.001)
    // 卡片上没有源时刻：镜头、光标、遮罩都画不上去；声音轨在这一段留空。
    #expect(edit.sourceTime(at: 5) == nil)
    #expect(edit.maskSpans().allSatisfy { $0.end <= 4.001 || $0.start >= 6.999 })
    #expect(!edit.mediaClips(.system).contains { ($0.timelineStart ?? 0) < 7 && ($0.timelineStart ?? 0) + $0.duration > 4.001 })
    // 后半段画面整体后移，源起点不变。
    let tail = try #require(edit.clips.first { $0.card == nil && abs(($0.timelineStart ?? 0) - 7) < 0.001 })
    #expect(abs(tail.sourceStart - 4) < 0.001)
    // 卡片的字照常画出来，画面层在卡片正中完全淡出。
    #expect(edit.activeTexts(at: 5.5).contains { $0.id == card.card?.text.id })
    #expect(edit.stage(at: 5.5).alpha < 0.01)

    edit.removeCard(id: id)
    try edit.validate(sourceDuration: 10)
    #expect(abs(edit.duration - 10) < 0.001)
    // 插入时切开的口子合回去了：画面与声音都还是一整块。
    #expect(edit.clips.count == 1 && abs(edit.clips[0].duration - 10) < 0.001)
    #expect(edit.mediaClips(.system).count == 1 && edit.mediaClips(.microphone).count == 1)
}

/// 旧版"全屏卡段"（定格片段 + 绑着它的全屏文字 + 人像定格）读取时换成卡片，成片长度与文字都不变。
@Test func legacyHoldCardsBecomeCards() throws {
    var edit = recording(10)
    let head = try #require(edit.clips.first?.id)
    let split = edit.splitMedia(.screen, id: head, at: 4)
    let tail = try #require(split)
    edit.rippleTimeline(from: 4, by: 3)
    var frozen = VideoClip(sourceStart: 4, duration: 3)
    frozen.timelineStart = 4; frozen.mediaDuration = 1.0 / 30; frozen.holdSource = head; frozen.title = "定格卡段"
    edit.clips.append(frozen)
    var still = VideoClip(sourceStart: 4, duration: 3)
    still.timelineStart = 4; still.mediaDuration = 1.0 / 30; still.holdSource = UUID()
    edit.cameraClips = (edit.cameraClips ?? []) + [still]
    var text = TextPreset.title.segment(start: 4, duration: 3)
    text.text = "第 2 章"; text.layout = .fullscreen; text.timelineStart = 4; text.holdClipID = frozen.id
    edit.addText(text)
    #expect(abs(edit.duration - 13) < 0.001)

    edit.migrateLegacyHoldCards()
    try edit.validate(sourceDuration: 10)
    #expect(abs(edit.duration - 13) < 0.001, "迁移后成片是 \(edit.duration) 秒")
    #expect(edit.textList.isEmpty)
    let card = try #require(edit.clips.first { $0.id == frozen.id }?.card)
    #expect(card.text.text == "第 2 章" && card.text.holdClipID == nil)
    #expect(edit.clips.first { $0.id == frozen.id }?.title == nil)
    #expect(!(edit.cameraClips ?? []).contains { $0.id == still.id })
    #expect(edit.clips.contains { $0.id == tail })
}

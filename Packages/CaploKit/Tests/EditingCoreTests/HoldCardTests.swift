import Foundation
import Testing
@testable import EditingCore

/// 全屏卡段：在成片中间插入一段真实时长，画面冻结、声音静音。
/// 实现上它就是一条只有一帧可用素材的录制画面片段，靠合成器已有的"保持末帧"机制持续输出那一帧。
private func recording(_ duration: Double) -> VideoEdit {
    var edit = VideoEdit(duration: duration)
    edit.materializeLayers()
    return edit
}

@Test func insertingAHoldCardExtendsTheFinishedVideoAndFreezesTheFrame() throws {
    var edit = recording(10)
    let before = edit.duration
    let inserted8976 = edit.insertHoldCard(at: 4, duration: 3, sourceDuration: 10, text: "第 2 章")
    let card = try #require(inserted8976)
    // 成片变长了整整一段卡段。
    #expect(abs(edit.duration - (before + 3)) < 0.001, "成片变成了 \(edit.duration) 秒")
    let text = try #require(edit.text(id: card))
    #expect(text.layout == .fullscreen && text.timelineStart == 4 && abs(text.duration - 3) < 0.001)
    let frozen = try #require(edit.clips.first { $0.id == text.holdClipID })
    // 定格片段：时长是卡段长度，可用素材只有一帧，源时间就是插入点那一刻。
    #expect(frozen.timelineStart == 4 && abs(frozen.duration - 3) < 0.001)
    #expect(frozen.playableDuration < 0.05, "可用素材有 \(frozen.playableDuration) 秒，不是一帧")
    #expect(abs(frozen.sourceStart - 4) < 0.001, "冻结的是源 \(frozen.sourceStart) 秒，不是插入点那一帧")
    try edit.validate(sourceDuration: 10)

    // 插入点之后的画面整体后移。
    let after = edit.clips.filter { $0.id != frozen.id }.sorted { ($0.timelineStart ?? 0) < ($1.timelineStart ?? 0) }
    #expect(after.count == 2, "插入点在片段中间，应当先切成两块")
    #expect(abs((after[1].timelineStart ?? 0) - 7) < 0.001, "后半段落在 \(after[1].timelineStart ?? -1) 秒")
    #expect(abs(after[1].sourceStart - 4) < 0.001, "后半段的源起点被动了")
}

@Test func removingAHoldCardPutsEverythingBack() throws {
    var edit = recording(10)
    let original = edit
    let inserted568 = edit.insertHoldCard(at: 4, duration: 3, sourceDuration: 10)
    let card = try #require(inserted568)
    #expect(abs(edit.duration - 13) < 0.001)
    edit.removeHoldCard(textID: card)
    #expect(abs(edit.duration - 10) < 0.001, "删掉卡段之后成片是 \(edit.duration) 秒")
    #expect(edit.textList.isEmpty && edit.clips.allSatisfy { $0.title != "定格卡段" })
    // 片段被切成两块这件事留下了，但时间轴回到原样。
    let ends = edit.clips.map { ($0.timelineStart ?? 0) + $0.duration }.max() ?? 0
    #expect(abs(ends - (original.clips.map { ($0.timelineStart ?? 0) + $0.duration }.max() ?? 0)) < 0.001)
    try edit.validate(sourceDuration: 10)
}


import Foundation
import Testing
@testable import EditingCore

/// 字幕编辑的边角：清空文本后分割、合并超长、导入的合并语义、导出再导入的往返。
/// 这几条都是「用户能做到、而且做了会出事」的路径。
private func edit(clips: [(Double, Double)]) -> VideoEdit {
    var value = VideoEdit(duration: 0)
    value.clips = clips.map { VideoClip(sourceStart: $0.0, duration: $0.1) }
    return value
}

@Test func splittingACueWithNoTextIsRefusedInsteadOfCrashing() {
    var value = edit(clips: [(0, 10)])
    value.captionList = [CaptionCue(sourceStart: 0, sourceEnd: 4, text: "")]
    let id = value.captionList[0].id
    // 之前这里会 characters[0..<1] 数组越界，整个 App 当场退出。
    #expect(value.splitCaption(id: id, atSource: 2) == nil)
    #expect(value.captionList.count == 1)
    // 只剩一个字同样切不出两句。
    value.updateCaption(id: id) { $0.text = "字" }
    #expect(value.splitCaption(id: id, atSource: 2) == nil)
    // 两个字就可以了。
    value.updateCaption(id: id) { $0.text = "两字" }
    #expect(value.splitCaption(id: id, atSource: 2) != nil)
}

@Test func mergingTwoLongCuesTruncatesInsteadOfFailingValidation() throws {
    var value = edit(clips: [(0, 20)])
    let long = String(repeating: "字", count: 300)
    value.captionList = [CaptionCue(sourceStart: 0, sourceEnd: 4, text: long),
                         CaptionCue(sourceStart: 4, sourceEnd: 8, text: long)]
    let first = value.captionList[0].id, second = value.captionList[1].id
    value.mergeCaption(id: first, with: second)
    #expect(value.captionList.count == 1)
    #expect(value.captionList[0].text.count == CaptionCue.textLimit, "合并后是 \(value.captionList[0].text.count) 字")
    try value.validate(sourceDuration: 20)
}

@Test func importedCaptionsReplaceOverlappingLinesAndKeepTheRest() {
    var value = edit(clips: [(0, 20)])
    var edited = CaptionCue(sourceStart: 2, sourceEnd: 4, text: "用户改过的")
    edited.locked = true
    value.captionList = [CaptionCue(sourceStart: 0, sourceEnd: 2, text: "自动转写的"), edited,
                         CaptionCue(sourceStart: 10, sourceEnd: 12, text: "不相干的一句")]
    value.mergeImportedCaptions([CaptionCue(sourceStart: 0, sourceEnd: 2, text: "导入的第一句"),
                                 CaptionCue(sourceStart: 2, sourceEnd: 4, text: "导入的第二句")])
    let texts = value.captionList.map { $0.text }
    // 重叠的两句让位给导入的；不重叠的保留；绝不出现同一段话两条。
    #expect(texts == ["导入的第一句", "导入的第二句", "不相干的一句"], "得到 \(texts)")
    #expect(value.captionList.count == 3)
}

@Test func importedSubtitlesAreClampedToTheMaterialInsteadOfRejectingTheWholeFile() throws {
    var value = edit(clips: [(0, 6)])
    // 三条：正常、末尾越界、完全在片子之外。
    let parsed = CaptionFile.parse("""
    1
    00:00:01,000 --> 00:00:02,000
    正常的一句

    2
    00:00:05,000 --> 00:00:12,000
    末尾越出片长

    3
    00:00:20,000 --> 00:00:22,000
    完全在片子之外
    """, into: value)
    #expect(parsed.map { $0.text } == ["正常的一句", "末尾越出片长"], "得到 \(parsed.map { $0.text })")
    #expect(parsed[1].sourceEnd <= 6.001, "越界那句没被夹住，结束在 \(parsed[1].sourceEnd)")
    value.mergeImportedCaptions(parsed)
    // 越界的一条不该让整批作废，也不该让工程校验失败。
    try value.validate(sourceDuration: 6)
}

@Test func exportingThenImportingCaptionsRoundTripsWithoutRejection() throws {
    var value = edit(clips: [(0, 6)])
    var style = CaptionStyle(); style.tail = 0.35; style.minHold = 1.0
    value.captionStyle = style
    // 最后一句贴着片尾：导出时会带上「说完停留」，成片时间因此超过片长。
    value.captionList = [CaptionCue(sourceStart: 1, sourceEnd: 2, text: "第一句"),
                         CaptionCue(sourceStart: 5, sourceEnd: 5.9, text: "贴着片尾的一句")]
    let text = CaptionFile.srt(value)
    let parsed = CaptionFile.parse(text, into: value)
    #expect(parsed.count == 2, "导回来只剩 \(parsed.count) 句：\(text)")
    value.mergeImportedCaptions(parsed)
    #expect(value.captionList.count == 2, "往返一次变成了 \(value.captionList.count) 句")
    try value.validate(sourceDuration: 6)
}

@Test func addingOverlaysWhereTheTimelineIsEmptyIsRefused() {
    // 中间挖掉一块：成片 0…2 有画面、2…4 空白、4…6 有画面。
    var value = VideoEdit(duration: 0)
    var head = VideoClip(sourceStart: 0, duration: 2); head.timelineStart = 0
    var tail = VideoClip(sourceStart: 4, duration: 2); tail.timelineStart = 4
    value.clips = [head, tail]
    // 空白处映射不出源时间，不能把成片秒数当源秒数写进去。
    #expect(value.insertMask(at: 3, duration: 2, sourceDuration: 6) == nil)
    #expect(value.insertText(at: 3, duration: 2, sourceDuration: 6) == nil)
    #expect(value.maskList.isEmpty && value.textList.isEmpty)
    // 有画面的地方照常。
    #expect(value.insertMask(at: 1, duration: 1, sourceDuration: 6) != nil)
    #expect(abs((value.maskList.first?.start ?? -1) - 1) < 0.001)
}

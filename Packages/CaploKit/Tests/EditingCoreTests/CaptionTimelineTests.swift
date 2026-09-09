import Foundation
import Testing
@testable import EditingCore

/// 字幕的数据契约：时间存源域所以跟着剪辑走、逐词高亮在剪辑之后仍对得上、
/// 显示时段会提前出现与停留但绝不与下一句重叠、SRT 按成片时间导出、导入按成片时间换算回源时间。
private func edit(clips: [(Double, Double)]) -> VideoEdit {
    var value = VideoEdit(duration: 0)
    value.clips = clips.map { VideoClip(sourceStart: $0.0, duration: $0.1) }
    return value
}
private func cue(_ start: Double, _ end: Double, _ text: String, words: [(Double, Double, String)] = []) -> CaptionCue {
    CaptionCue(sourceStart: start, sourceEnd: end, text: text,
               words: words.isEmpty ? nil : words.map { CaptionWord(start: $0.0, end: $0.1, text: $0.2) })
}

@Test func captionSplitsWithACutAndKeepsItsSourceTimes() {
    // 源 0…12，中间剪掉 5…8。一句 3…10 裂成 3…5 与 5…7（成片时间）。
    var value = edit(clips: [(0, 5), (8, 4)])
    value.captionList = [cue(3, 10, "把留白调到四十")]
    let spans = value.captionSpans()
    #expect(spans.count == 2)
    #expect(abs(spans[0].start - 3) < 0.001 && abs(spans[0].duration - 2) < 0.001)
    #expect(abs(spans[1].start - 5) < 0.001 && abs(spans[1].duration - 2) < 0.001)
    #expect(spans[0].tailClipped && spans[1].headClipped && !spans[0].headClipped)
    #expect(value.captionList[0].sourceStart == 3 && value.captionList[0].sourceEnd == 10)
}

@Test func captionStopsAtTheHeldLastFrameWhereMasksDoNot() {
    // 媒体只有 2 秒但块占 4 秒：后两秒是静止的末帧，那里没人说话，字幕不该拖过去。
    var value = VideoEdit(duration: 0)
    var clip = VideoClip(sourceStart: 0, duration: 4); clip.mediaDuration = 2
    value.clips = [clip]
    value.captionList = [cue(0, 4, "一句话")]
    #expect(abs((value.captionSpans().first?.duration ?? 0) - 2) < 0.001)
    // 遮罩相反，末帧上照样要遮：末帧那一截是冻住的第二段，两段加起来盖满整块。
    value.addMask(MaskSegment(start: 0, duration: 4, x: 0.5, y: 0.5, width: 0.2, height: 0.1))
    #expect(abs(value.maskSpans().reduce(0) { $0 + $1.duration } - 4) < 0.001)
    #expect(value.activeMasks(at: 3.5).count == 1)
}

@Test func displayRangeLeadsHoldsAndNeverOverlapsTheNextLine() {
    var value = edit(clips: [(0, 30)])
    var style = CaptionStyle()
    style.lead = 0.06; style.tail = 0.35; style.minHold = 1.0; style.bridge = 0.25
    value.captionStyle = style
    value.captionList = [cue(1, 1.4, "短"), cue(3, 5, "长一点的一句")]
    let spans = value.captionSpans()
    let first = value.captionDisplayRange(spans[0], style: style, nextStart: spans[1].start)
    // 提前 0.06 出现，说完停留 0.35，但不足最短 1 秒时补到 1 秒。
    #expect(abs(first.lowerBound - 0.94) < 0.001)
    #expect(abs(first.upperBound - 1.94) < 0.001)
    let second = value.captionDisplayRange(spans[1], style: style, nextStart: nil)
    #expect(abs(second.lowerBound - 2.94) < 0.001 && abs(second.upperBound - 5.35) < 0.001)
    // 两句挨得很近时，前一句一直显示到后一句出现前一刻，不闪断。
    value.captionList = [cue(1, 2, "上一句"), cue(2.4, 4, "下一句")]
    let tight = value.captionSpans()
    let held = value.captionDisplayRange(tight[0], style: style, nextStart: tight[1].start)
    let next = value.captionDisplayRange(tight[1], style: style, nextStart: nil)
    #expect(held.upperBound < next.lowerBound + 0.0011 && held.upperBound > next.lowerBound - 0.0011,
            "上一句结束在 \(held.upperBound)，下一句开始在 \(next.lowerBound)")
}

@Test func onlyOneCaptionShowsAtATime() {
    var value = edit(clips: [(0, 30)])
    value.captionList = [cue(1, 3, "第一句"), cue(3, 5, "第二句")]
    let spans = value.captionSpans()
    let state = value.activeCaption(at: 3.1, spans: spans)
    #expect(state?.text == "第二句")
    #expect(value.activeCaption(at: 20, spans: spans) == nil)
}

@Test func wordHighlightFollowsSpeechAndSurvivesACut() throws {
    // 源 0…12，剪掉 5…8。一句 3…10 带词表；成片 5.1 秒对应源 8.1 秒，正好是"四十"。
    var value = edit(clips: [(0, 5), (8, 4)])
    var style = CaptionStyle(); style.highlight = .color; style.evenSplit = false
    style.lead = 0; style.tail = 0; style.minHold = 0; style.bridge = 0; style.fadeIn = 0.001; style.fadeOut = 0.001
    value.captionStyle = style
    value.captionList = [cue(3, 10, "把留白调到四十",
                             words: [(3, 4, "把"), (4, 6, "留白"), (6, 8, "调到"), (8, 10, "四十")])]
    let spans = value.captionSpans()
    let early = try #require(value.activeCaption(at: 4.2, spans: spans))
    #expect(early.words[early.activeWord].text == "留白", "成片 4.2 秒高亮的是 \(early.words[early.activeWord].text)")
    let late = try #require(value.activeCaption(at: 5.2, spans: spans))
    #expect(late.words[late.activeWord].text == "四十", "剪辑之后成片 5.2 秒高亮的是 \(late.words[late.activeWord].text)")
    // 词在整句里的位置也要对，渲染才知道给哪几个字上色。
    #expect(late.words[late.activeWord].location == 5 && late.words[late.activeWord].length == 2)
}

@Test func evenSplitFallsBackToCharactersWhenWordTimingsAreUseless() throws {
    // 中文常常整句只给一段词边界；按字均分兜底后每个字都有自己的时间。
    var value = edit(clips: [(0, 20)])
    var style = CaptionStyle(); style.highlight = .color; style.evenSplit = true
    style.lead = 0; style.tail = 0; style.minHold = 0; style.fadeIn = 0.001; style.fadeOut = 0.001
    value.captionStyle = style
    value.captionList = [cue(0, 4, "把留白调到四十", words: [(0, 4, "把留白调到四十")])]
    let state = try #require(value.activeCaption(at: 2.1, spans: value.captionSpans()))
    #expect(state.words.count == 7, "按字均分后有 \(state.words.count) 个词")
    // 7 个字均分 4 秒，每字 0.571 秒；2.1 秒落在第 4 个字上。
    #expect(state.words[state.activeWord].text == "调")
}

@Test func splittingACueCutsTextAtTheWordBoundary() throws {
    var value = edit(clips: [(0, 20)])
    value.captionList = [cue(0, 4, "把留白调到四十", words: [(0, 1, "把"), (1, 2, "留白"), (2, 3, "调到"), (3, 4, "四十")])]
    let id = value.captionList[0].id
    guard let tail = value.splitCaption(id: id, atSource: 2.5) else { Issue.record("没能分割"); return }
    #expect(value.captionList.count == 2)
    #expect(value.captionList[0].text == "把留白调到" && value.captionList[1].text == "四十")
    #expect(value.captionList[0].sourceEnd == 2.5 && value.captionList[1].sourceStart == 2.5)
    #expect(value.captionList[1].id == tail)
    // 合并回去要还原成一句。
    value.mergeCaption(id: id, with: tail)
    #expect(value.captionList.count == 1 && value.captionList[0].text == "把留白调到四十")
    #expect(value.captionList[0].sourceStart == 0 && value.captionList[0].sourceEnd == 4)
}

@Test func retranscribingKeepsTheLinesTheUserEdited() {
    var value = edit(clips: [(0, 20)])
    var edited = cue(2, 4, "用户改过的一句"); edited.locked = true
    value.captionList = [cue(0, 2, "旧的一句"), edited]
    value.mergeTranscription([cue(0, 2, "新的一句"), cue(2.5, 3.5, "会被丢掉"), cue(5, 6, "新增的一句")])
    let texts = value.captionList.map(\.text)
    #expect(texts.contains("用户改过的一句"), "锁住的句子被冲掉了")
    #expect(texts.contains("新的一句") && texts.contains("新增的一句"))
    #expect(!texts.contains("会被丢掉"), "与锁住的句子重叠的新结果应当丢弃")
    #expect(value.captionList.map(\.sourceStart) == value.captionList.map(\.sourceStart).sorted())
}

@Test func srtMergesAdjacentHalvesAndMarksTrulySplitLines() {
    var style = CaptionStyle(); style.lead = 0; style.tail = 0; style.minHold = 0; style.bridge = 0
    // 剪掉中间一段之后两半在成片上首尾相接：输出一条，不加省略号——观众看到的本来就是连续的一句。
    var joined = edit(clips: [(0, 5), (8, 4)])
    joined.captionStyle = style
    joined.captionList = [cue(3, 10, "把留白调到四十")]
    let merged = CaptionFile.srt(joined)
    #expect(merged.contains("00:00:03,000 --> 00:00:07,000"), "\(merged)")
    #expect(!merged.contains("…"), "首尾相接的两半不该加省略号：\(merged)")

    // 两半之间真的隔着一段别的画面：输出两条，各自在断口加省略号。
    var gapped = VideoEdit(duration: 0)
    var head = VideoClip(sourceStart: 0, duration: 5); head.timelineStart = 0
    var tail = VideoClip(sourceStart: 8, duration: 4); tail.timelineStart = 6
    gapped.clips = [head, tail]
    gapped.captionStyle = style
    gapped.captionList = [cue(3, 10, "把留白调到四十")]
    let text = CaptionFile.srt(gapped)
    #expect(text.contains("00:00:03,000 --> 00:00:05,000"), "\(text)")
    #expect(text.contains("00:00:06,000 --> 00:00:08,000"), "\(text)")
    #expect(text.contains("把留白调到四十…") && text.contains("…把留白调到四十"), "\(text)")
    #expect(CaptionFile.vtt(gapped).hasPrefix("WEBVTT\n\n") && CaptionFile.vtt(gapped).contains("00:00:03.000"))
}

@Test func importedSubtitlesMapTimelineTimeBackToSource() throws {
    var value = edit(clips: [(0, 5), (8, 4)])
    // 成片 5.5 秒落在第二个片段里，对应源 8.5 秒。
    let parsed = CaptionFile.parse("""
    1
    00:00:01,000 --> 00:00:02,000
    第一句

    2
    00:00:05,500 --> 00:00:06,500
    第二句
    """, into: value)
    #expect(parsed.count == 2)
    #expect(abs(parsed[0].sourceStart - 1) < 0.01)
    #expect(abs(parsed[1].sourceStart - 8.5) < 0.01, "导入后落在源 \(parsed[1].sourceStart) 秒")
    let allLocked = parsed.allSatisfy { $0.locked }
    #expect(allLocked, "导入的句子要锁住，重新转写不该冲掉它们")
    value.captionList = parsed
    // 导出再导入应当回到同一处。
    let round = CaptionFile.parse(CaptionFile.srt(value), into: value)
    #expect(abs(round[1].sourceStart - parsed[1].sourceStart) < 0.15)
}

@Test func addingCaptionsDoesNotBumpTheSchemaVersion() throws {
    var value = VideoEdit(duration: 10)
    value.captionList = [cue(1, 3, "一句话")]
    #expect(value.schemaVersion <= VideoEdit.writtenSchemaVersion)
    try value.validate(sourceDuration: 10)
    value.captionList = []
    #expect(value.captions == nil)
    // 越界与坏值一律拒绝。
    var broken = VideoEdit(duration: 10); broken.captionList = [cue(1, 30, "太长了")]
    #expect(throws: EditError.self) { try broken.validate(sourceDuration: 10) }
}

@Test func oldProjectWithoutCaptionKeyStillDecodes() throws {
    let original = VideoEdit(duration: 6)
    let data = try JSONEncoder().encode(original)
    #expect(!(try #require(String(data: data, encoding: .utf8))).contains("\"captions\""))
    #expect(try JSONDecoder().decode(VideoEdit.self, from: data) == original)
}

@Test func draggingACaptionMovesItsWordsAlong() throws {
    var value = edit(clips: [(0, 20)])
    value.captionList = [cue(2, 4, "两个词", words: [(2, 3, "两个"), (3, 4, "词")])]
    let id = value.captionList[0].id
    value.dragCaption(id: id, edge: .body, delta: 3, sourceDuration: 20)
    let moved = try #require(value.caption(id: id))
    #expect(moved.sourceStart == 5 && moved.sourceEnd == 7)
    #expect(moved.words?.map(\.start) == [5, 6], "词表没跟着挪，高亮会和句子错开")
    value.dragCaption(id: id, edge: .trailing, delta: -1, sourceDuration: 20)
    #expect(value.caption(id: id)?.sourceEnd == 6)
}

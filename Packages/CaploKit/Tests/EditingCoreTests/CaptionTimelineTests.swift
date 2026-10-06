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


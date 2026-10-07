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

    // 外部 VTT：带 BOM、时间行后跟显示设置、用带空格的空行与旧式回车分隔，三句都要读进来。
    let vtt = "\u{FEFF}WEBVTT\r\r00:00:01.000 --> 00:00:01.800 align:start position:10%\r第一句\r \r00:00:02.000 --> 00:00:02.900 line:0\r第二句\r\r3\r00:00:03.000 --> 00:00:03.500\r第三句\r"
    let imported = CaptionFile.parse(vtt, into: value)
    #expect(imported.map(\.text) == ["第一句", "第二句", "第三句"], "VTT 只读到 \(imported.map(\.text))")
}


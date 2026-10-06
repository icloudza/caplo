import Foundation
import Testing
@testable import EditingCore

/// 区域遮罩的数据契约：强度编解码永远 fail-closed、时间存源域所以剪辑之后自己裂开与合拢、
/// 敏感遮罩硬切且两端留余量、关键帧按源时间取值、含遮罩的工程必须标成版本 7。
private func edit(clips: [(Double, Double)]) -> VideoEdit {
    var value = VideoEdit(duration: 0)
    value.clips = clips.map { VideoClip(sourceStart: $0.0, duration: $0.1) }
    return value
}
private func mask(_ start: Double, _ duration: Double, kind: MaskSegment.Kind = .sensitive) -> MaskSegment {
    MaskSegment(start: start, duration: duration, x: 0.5, y: 0.5, width: 0.2, height: 0.1, kind: kind)
}

@Test func maskSurvivesACutBySplittingItselfInSourceTime() {
    // 源 0…12 一整条，中间剪掉 5…8：遮罩 3…10 应当裂成两段，成片上是 3…5 和 5…7。
    var value = edit(clips: [(0, 5), (8, 4)])
    value.addMask(mask(3, 7))
    let spans = value.maskSpans().sorted { $0.start < $1.start }
    #expect(spans.count == 2)
    #expect(abs(spans[0].start - 3) < 0.001 && abs(spans[0].duration - 2) < 0.001 && abs(spans[0].offset) < 0.001)
    #expect(abs(spans[1].start - 5) < 0.001 && abs(spans[1].duration - 2) < 0.001 && abs(spans[1].offset - 5) < 0.001)
    // 源时间没有被改写，撤销剪辑就回到一整条。
    #expect(value.maskList[0].start == 3 && value.maskList[0].duration == 7)
}


import Foundation
import Testing
@testable import EditingCore

/// 文字层的数据契约：时间存源域所以跟着剪辑走、动画相位不因剪辑重放、
/// 进出时长超过本段时按比例压缩、打字机按比例揭字、含文字层的工程标成版本 8。
private func edit(clips: [(Double, Double)]) -> VideoEdit {
    var value = VideoEdit(duration: 0)
    value.clips = clips.map { VideoClip(sourceStart: $0.0, duration: $0.1) }
    return value
}

@Test func textSurvivesACutBySplittingWithoutReplayingItsEntrance() {
    // 源 0…12，中间剪掉 5…8；文字 3…10 裂成两段，第二段的动画相位接着走而不是从头再来。
    var value = edit(clips: [(0, 5), (8, 4)])
    var label = TextSegment(start: 3, duration: 7, text: "产品演示")
    label.enterKind = .fade; label.enterDuration = 1; label.exitKind = .none; label.exitDuration = 0
    value.addText(label)
    let spans = value.textSpans().sorted { $0.start < $1.start }
    #expect(spans.count == 2)
    #expect(abs(spans[1].offset - 5) < 0.001)
    // 成片 5.0 秒是第二段的起点，对应文字自身的第 5 秒——进场早就走完了。
    let later = value.activeTexts(at: 5.05, spans: spans)
    #expect(later.count == 1 && later[0].animation.alpha > 0.999, "剪辑之后进场动画重放了")
    // 文字从源 3 秒起，也就是成片 3 秒；那一刻才在淡入。
    let early = value.activeTexts(at: 3.2, spans: spans)
    #expect(early.count == 1 && early[0].animation.alpha < 0.9 && early[0].animation.alpha > 0.001)
}


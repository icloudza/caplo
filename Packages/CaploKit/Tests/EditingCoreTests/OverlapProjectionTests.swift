import Foundation
import Testing
@testable import EditingCore

/// 片段重叠时（选中一块画面按 ⌘D 就会重叠），被盖住那一段素材根本不出画，
/// 它上面的遮罩 / 文字 / 字幕也不该出现在画面上。
/// 数组靠前的片段盖住靠后的（见 TimelineIndex 的扫描线），所以下面 B 的前三秒是看不见的。
private func overlappingEdit() -> VideoEdit {
    var value = VideoEdit(duration: 0)
    var front = VideoClip(sourceStart: 0, duration: 4); front.timelineStart = 0
    var back = VideoClip(sourceStart: 10, duration: 4); back.timelineStart = 1
    value.clips = [front, back]
    return value
}

@Test func overlaysOnAHiddenClipAreNotProjected() {
    var value = overlappingEdit()
    // B 在成片上占 1…5，但 1…4 被 A 盖住，只有 4…5 真的出画（对应源 13…14）。
    value.addMask(MaskSegment(start: 11, duration: 1, x: 0.5, y: 0.5, width: 0.2, height: 0.1))
    #expect(value.maskSpans().isEmpty, "被盖住的素材上的遮罩仍然画了出来：\(value.maskSpans().map { $0.start })")

    value.addText(TextSegment(start: 11, duration: 1, text: "被盖住的文字"))
    #expect(value.textSpans().isEmpty, "被盖住的素材上的文字仍然画了出来")

    value.captionList = [CaptionCue(sourceStart: 11, sourceEnd: 12, text: "被盖住的字幕")]
    #expect(value.captionSpans().isEmpty, "被盖住的素材上的字幕仍然画了出来")
}

@Test func overlaysOnTheVisiblePartOfAnOverlappedClipStillShow() {
    var value = overlappingEdit()
    // 源 13…14 是 B 真正出画的那一段，落在成片 4…5。
    value.addMask(MaskSegment(start: 13, duration: 1, x: 0.5, y: 0.5, width: 0.2, height: 0.1))
    let spans = value.maskSpans()
    #expect(spans.count == 1)
    #expect(abs((spans.first?.start ?? 0) - 4) < 0.001 && abs((spans.first?.duration ?? 0) - 1) < 0.001,
            "投影到了 \(spans.map { ($0.start, $0.duration) })")
    // 跨过遮挡边界的一条：只有露出来的那半段算数。
    value.maskList = [MaskSegment(start: 12, duration: 2, x: 0.5, y: 0.5, width: 0.2, height: 0.1)]
    let crossing = value.maskSpans()
    #expect(crossing.count == 1 && abs(crossing[0].start - 4) < 0.001 && abs(crossing[0].duration - 1) < 0.001,
            "跨边界的一条投影成了 \(crossing.map { ($0.start, $0.duration) })")
    // 动画相位要按遮罩自身的时间算：这一段是它的第 1 秒开始。
    #expect(abs(crossing[0].offset - 1) < 0.001, "相位偏移是 \(crossing[0].offset)")
}

@Test func projectionIsUnchangedForNormalNonOverlappingClips() {
    var value = VideoEdit(duration: 0)
    value.clips = [VideoClip(sourceStart: 0, duration: 5), VideoClip(sourceStart: 8, duration: 4)]
    value.addMask(MaskSegment(start: 3, duration: 7, x: 0.5, y: 0.5, width: 0.2, height: 0.1))
    let spans = value.maskSpans().sorted { $0.start < $1.start }
    #expect(spans.count == 2)
    #expect(abs(spans[0].start - 3) < 0.001 && abs(spans[0].duration - 2) < 0.001)
    #expect(abs(spans[1].start - 5) < 0.001 && abs(spans[1].duration - 2) < 0.001)
    #expect(abs(spans[1].offset - 5) < 0.001)
}

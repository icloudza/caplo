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

@Test func enterAndExitCompressWhenTheyExceedTheSegment() {
    var label = TextSegment(start: 0, duration: 1, text: "标题")
    label.enterDuration = 1.2; label.exitDuration = 0.8
    let timings = label.timings
    #expect(abs(timings.enter + timings.exit - 1) < 0.0001, "压缩后总和是 \(timings.enter + timings.exit)")
    #expect(abs(timings.enter / timings.exit - 1.5) < 0.0001, "压缩要按原比例")
    // 压缩之后中间没有"完全显示"的一刻，但也不该出现空档或跳变。
    for elapsed in stride(from: 0.0, through: 1.0, by: 0.05) {
        let alpha = label.animation(elapsed: elapsed).alpha
        #expect(alpha.isFinite && alpha >= 0 && alpha <= 1.0001, "\(elapsed) 秒处 alpha 是 \(alpha)")
    }
}

@Test func popOvershootsALittleAndSettlesExactlyAtOne() {
    var label = TextSegment(start: 0, duration: 3, text: "3×")
    label.enterKind = .pop; label.enterDuration = 0.5; label.exitKind = .none; label.exitDuration = 0
    var peak = 0.0
    for elapsed in stride(from: 0.0, through: 0.5, by: 0.005) { peak = max(peak, label.animation(elapsed: elapsed).scale) }
    #expect(peak > 1.01 && peak < 1.05, "回弹峰值是 \(peak)，应当克制但看得见")
    #expect(abs(label.animation(elapsed: 1.0).scale - 1) < 0.0001)
    #expect(abs(label.animation(elapsed: 0).scale - 0.72) < 0.0001)
}

@Test func typewriterRevealsProportionallyAndHoldsWhenDone() {
    var value = edit(clips: [(0, 10)])
    var label = TextSegment(start: 0, duration: 4, text: "npm run build")
    label.enterKind = .type; label.enterDuration = 1.0; label.exitKind = .none; label.exitDuration = 0
    value.addText(label)
    let spans = value.textSpans()
    let count = label.text.count
    #expect(value.activeTexts(at: 0.5, spans: spans).first?.revealedCount == Int((Double(count) * 0.5).rounded()))
    #expect(value.activeTexts(at: 2.0, spans: spans).first?.revealedCount == count)
    // 刚开始一个字都没有，但这一帧仍然要画（否则底板会闪一下）。
    let first = value.activeTexts(at: 0, spans: spans).first
    #expect(first?.revealedCount == 0 && first != nil)
}

@Test func emptyTextIsNotDrawnAtAll() {
    var value = edit(clips: [(0, 10)])
    value.addText(TextSegment(start: 0, duration: 4, text: ""))
    #expect(value.activeTexts(at: 1).isEmpty)
}

@Test func addingTextDoesNotBumpTheSchemaVersion() throws {
    var value = VideoEdit(duration: 10)
    value.addText(TextSegment(start: 1, duration: 3, text: "标题"))
    #expect(value.schemaVersion <= VideoEdit.writtenSchemaVersion)
    try value.validate(sourceDuration: 10)
    value.addMask(MaskSegment(start: 1, duration: 2, x: 0.5, y: 0.5, width: 0.2, height: 0.1))
    value.removeText(id: value.textList[0].id)
    #expect(value.texts == nil && value.schemaVersion <= VideoEdit.writtenSchemaVersion)
    try value.validate(sourceDuration: 10)
}

@Test func oldProjectWithoutTextKeyStillDecodes() throws {
    var original = VideoEdit(duration: 6)
    original.focuses = [FocusSegment(start: 0, duration: 2, x: 0.5, y: 0.5)]
    let data = try JSONEncoder().encode(original)
    #expect(!(try #require(String(data: data, encoding: .utf8))).contains("\"texts\""))
    #expect(try JSONDecoder().decode(VideoEdit.self, from: data) == original)
}

@Test func textValidationRejectsBrokenValues() {
    var value = VideoEdit(duration: 10)
    value.addText(TextSegment(start: 1, duration: 3, text: "标题"))
    for broken in [{ (t: inout TextSegment) in t.size = 1000 }, { $0.lineHeight = .nan }, { $0.duration = 0 },
                   { $0.maxWidth = 0 }, { $0.opacity = 2 }, { $0.start = 9 },
                   { $0.text = String(repeating: "字", count: TextSegment.textLimit + 1) }] as [(inout TextSegment) -> Void] {
        var copy = value
        copy.updateText(id: copy.textList[0].id, broken)
        #expect(throws: EditError.self) { try copy.validate(sourceDuration: 10) }
    }
}

@Test func draggingTextKeepsItInSourceTime() {
    var value = edit(clips: [(0, 10)])
    guard let id = value.insertText(at: 2, duration: 3, sourceDuration: 10, preset: .title) else { Issue.record("没能新建文字"); return }
    value.dragText(id: id, edge: .trailing, delta: -1, sourceDuration: 10)
    #expect(abs((value.text(id: id)?.duration ?? 0) - 2) < 0.0001)
    value.dragText(id: id, edge: .body, delta: 3, sourceDuration: 10)
    #expect(abs((value.text(id: id)?.start ?? 0) - 5) < 0.0001 && value.text(id: id)?.timelineStart == nil)
    // 拖过素材末尾会被顶住，不会变成负时长或越界。
    value.dragText(id: id, edge: .body, delta: 100, sourceDuration: 10)
    #expect(abs((value.text(id: id)?.start ?? 0) - 8) < 0.0001)
}

@Test func presetsAreRecognisableAfterBeingApplied() {
    for preset in TextPreset.allCases {
        let value = preset.segment(start: 0, duration: 3)
        #expect(TextPreset.matching(value) == preset, "\(preset.name) 套用后认不出来了")
        #expect(value.isValid, "\(preset.name) 的参数不合法")
        #expect(value.preset == preset.name)
    }
}

@Test func textNumbersFollowTimelineOrder() {
    var value = edit(clips: [(0, 20)])
    let late = TextSegment(start: 10, duration: 2, text: "后"), early = TextSegment(start: 1, duration: 2, text: "先")
    value.addText(late); value.addText(early)
    let numbers = value.textNumbers()
    #expect(numbers[early.id] == 1 && numbers[late.id] == 2)
}

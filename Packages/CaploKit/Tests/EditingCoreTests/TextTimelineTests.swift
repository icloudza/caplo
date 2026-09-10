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

@Test func splitLayoutCollapsesTheCanvasPaddingAlongWithTheTransition() {
    // 分屏时留白收到 0，且随版式过渡插值；全屏和叠加不碰留白。
    var segment = TextPreset.title.segment(start: 0, duration: 4)
    segment.layout = .splitLeft
    #expect(segment.stageTarget.paddingScale == 0 && segment.stageTarget.split)
    segment.layout = .splitRight
    #expect(segment.stageTarget.paddingScale == 0)
    segment.layout = .fullscreen
    #expect(segment.stageTarget.paddingScale == 1)
    segment.layout = .overlay
    #expect(segment.stageTarget.paddingScale == 1 && segment.stageTarget.isIdentity)
    let half = StageTransform.blend(StageTransform(scale: 0.5, split: true, paddingScale: 0), progress: 0.5)
    #expect(abs(half.paddingScale - 0.5) < 0.000001)
    #expect(!StageTransform(paddingScale: 0).isIdentity)
    #expect(StageTransform.blend(StageTransform(paddingScale: 0), progress: 0).isIdentity)
}

@Test func slideEntranceReachesFullOpacityEarlyButKeepsMovingToTheEnd() {
    // 「快显慢移」：白字压在浅色画面上时，半透明的中间态看着是一片灰，所以透明度前置，位移照旧走满。
    var label = TextSegment(start: 0, duration: 4, text: "产品演示")
    label.enterKind = .slideUp; label.enterDuration = 1; label.exitKind = .none; label.exitDuration = 0
    func state(_ t: Double) -> TextAnimationState { label.animation(elapsed: t) }
    // 起点仍然从全透明开始，不是硬切。
    #expect(state(0).alpha < 0.001 && abs(state(0).offset - TextSegment.slide) < 0.000001)
    // 用户截到的那几帧：原本 30% 处只有 16% 不透明度，现在接近一半，45% 处已经全实。
    #expect(state(0.30).alpha > 0.44 && state(0.30).alpha < 0.5)
    #expect(state(0.45).alpha > 0.999)
    // 透明度到位之后位移还没走完，入场时长仍然是有意义的。
    #expect(state(0.45).offset > 0.02 && state(0.70).offset > 0.005)
    #expect(state(0.999).offset < 0.0005)
    // 全程单调不回头。
    var previous = -1.0
    for step in 0...100 {
        let value = state(Double(step) / 100)
        #expect(value.alpha >= previous - 0.000001, "透明度在 \(step)% 处回落了")
        previous = value.alpha
    }
    // 下滑是同一条曲线，只是位移反向。
    label.enterKind = .slideDown
    #expect(abs(state(0.30).alpha - 0.457) < 0.01 && state(0.30).offset < 0)
}

@Test func legacyAutoTextColorLandsOnWhatItUsedToRender() throws {
    // 「自动」当年按画布背景亮度在墨黑与白之间选。删掉它之后，旧工程按同一条规则落成固定色，画面不变。
    func decoded(background: CanvasBackground) throws -> VideoEdit {
        var value = VideoEdit(duration: 4)
        value.layout.background = background
        var text = TextSegment(start: 0, duration: 2, text: "标题")
        text.color = TextSegment.Palette(rawValue: "auto")
        text.plateColor = TextSegment.Palette(rawValue: "auto")
        value.addText(text)
        var style = CaptionStyle(); style.color = TextSegment.Palette(rawValue: "auto")
        value.captionStyle = style
        var reloaded = try JSONDecoder().decode(VideoEdit.self, from: JSONEncoder().encode(value))
        // 存进文件的一直是一个字符串，换成结构体之后也没变。
        #expect(reloaded.textList[0].color.rawValue == "auto")
        reloaded.resolveLegacyAutoTextColors()
        return reloaded
    }
    // 深色背景当年取白。
    let dark = try decoded(background: .iris)
    #expect(dark.textList[0].color == .white && dark.textList[0].plateColor == .white)
    #expect(dark.captionStyle?.color == .white)
    // 浅色背景当年取墨黑。
    let light = try decoded(background: .solidWhite)
    #expect(light.textList[0].color == .ink)
    // 已经是固定色或自定义色的不动。
    var kept = VideoEdit(duration: 2)
    var text = TextSegment(start: 0, duration: 1, text: "标题")
    text.color = TextSegment.Palette(red: 1, green: 0, blue: 0)
    kept.addText(text); kept.resolveLegacyAutoTextColors()
    #expect(kept.textList[0].color.rawValue == "#FF0000")
}

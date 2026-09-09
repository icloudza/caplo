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

@Test func maskStrengthDecodingFailsClosedOnAnythingUnreadable() {
    #expect(MaskSegment.decode(MaskSegment.encode(effect: .blur, amount: 16)) == (.blur, 16))
    #expect(MaskSegment.decode(MaskSegment.encode(effect: .pixelate, amount: 24)) == (.pixelate, 24))
    // 超出范围的强度被夹进合法区间，而不是原样存下来。
    #expect(MaskSegment.encode(effect: .blur, amount: 5000) == MaskSegment.blurEncodingOffset + MaskSegment.amountRange.upperBound)
    // 坏数据一律回落到最强像素化：解不出来时宁可糊成一片，也绝不能变成"不打码"。
    for raw in [Double.nan, .infinity, -1, 0, 999, 2000, MaskSegment.blurEncodingOffset + 999] {
        let decoded = MaskSegment.decode(raw)
        #expect(decoded.effect == .pixelate && decoded.amount == MaskSegment.amountRange.upperBound, "\(raw) 解出了 \(decoded)")
    }
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

@Test func maskCoversTheHeldLastFrameWhereFocusDoesNot() {
    // 媒体只有 2 秒但块占了 4 秒，后两秒是保持的末帧——那一帧上照样印着密钥，必须继续遮。
    var value = VideoEdit(duration: 0)
    var clip = VideoClip(sourceStart: 0, duration: 4); clip.mediaDuration = 2
    value.clips = [clip]
    value.addMask(mask(0, 4))
    // 末帧那一截单独成段并且是冻住的：源时间不再往前走，遮罩的关键帧也停在最后一帧上。
    // 拉伸的写法在这个夹具上同样"盖满 4 秒"，却会让几秒长的定格把遮罩提前演完。
    let spans = value.maskSpans().sorted { $0.start < $1.start }
    #expect(abs(spans.reduce(0) { $0 + $1.duration } - 4) < 0.001, "遮罩没盖满整块，末帧会露出来")
    #expect(spans.count == 2 && spans[1].frozen && abs(spans[1].start - 2) < 0.001)
    for time in [0.5, 1.9, 2.1, 3.9] { #expect(value.activeMasks(at: time).count == 1, "\(time) 秒处没有遮罩") }
    // 聚焦相反，它只在真正有画面的区间生效。
    value.focuses = [FocusSegment(start: 0, duration: 4, x: 0.5, y: 0.5)]
    #expect(abs((value.focusSpans().first?.duration ?? 0) - 2) < 0.001)
}

@Test func sensitiveMaskCutsHardAndPadsBothEnds() {
    var value = edit(clips: [(0, 10)])
    var sensitive = mask(2, 3); sensitive.fadeIn = 1; sensitive.fadeOut = 1
    value.addMask(sensitive)
    let spans = value.maskSpans()
    // 不透明度恒为 1：淡入淡出等于把原文按比例混回画面，逐帧截图就能读出来。
    for time in [2.0, 2.02, 3.5, 4.98] {
        #expect(value.maskState(sensitive, at: time, spans: spans)?.alpha == 1, "\(time) 秒处不是全不透明")
    }
    // 两端各多盖 0.10 秒，转场那一两帧不会漏。
    #expect(value.maskState(sensitive, at: 1.95, spans: spans) != nil && value.maskState(sensitive, at: 5.05, spans: spans) != nil)
    #expect(value.maskState(sensitive, at: 1.85, spans: spans) == nil && value.maskState(sensitive, at: 5.15, spans: spans) == nil)
}

@Test func highlightMaskFadesAndDoesNotGetTheSafetyPad() {
    var value = edit(clips: [(0, 10)])
    var spotlight = mask(2, 3, kind: .highlight)
    spotlight.fadeIn = 0.5; spotlight.fadeOut = 0.5
    value.addMask(spotlight)
    let spans = value.maskSpans()
    #expect(value.maskState(spotlight, at: 1.95, spans: spans) == nil)
    let entering = try! #require(value.maskState(spotlight, at: 2.25, spans: spans))
    #expect(entering.alpha > 0.05 && entering.alpha < 0.95, "淡入中途的强度是 \(entering.alpha)")
    #expect((value.maskState(spotlight, at: 3.5, spans: spans)?.alpha ?? 0) > 0.999)
}

@Test func maskKeyframesFollowSourceTimeAcrossACut() {
    // 遮罩 0…10 跟着一个从左走到右的窗口；中间剪掉源 4…6 之后，
    // 成片 5 秒处看到的应当是源 7 秒的位置，而不是被剪辑带偏的第 5 秒。
    var value = edit(clips: [(0, 4), (6, 4)])
    var moving = mask(0, 10)
    moving.positionKeys = (0...10).map { MaskPointKeyframe(time: Double($0), x: Double($0) / 10, y: 0.5) }
    value.addMask(moving)
    let spans = value.maskSpans()
    let state = try! #require(value.maskState(moving, at: 5, spans: spans))
    #expect(abs(state.x - 0.7) < 0.001, "剪辑之后关键帧取到了 x = \(state.x)")
    let before = try! #require(value.maskState(moving, at: 2, spans: spans))
    #expect(abs(before.x - 0.2) < 0.001)
}

@Test func pinnedMaskIgnoresEditingAndStaysOnOutputTime() {
    var value = edit(clips: [(0, 4), (6, 4)])
    var pinned = mask(0, 3); pinned.timelineStart = 5
    value.addMask(pinned)
    let spans = value.maskSpans()
    #expect(spans.count == 1 && spans[0].clipID == nil && spans[0].start == 5)
    #expect(value.maskState(pinned, at: 6, spans: spans) != nil && value.maskState(pinned, at: 2, spans: spans) == nil)
}

/// 叠加层不再各自升一档版本号：加遮罩不改版本，旧版本打开只是少画一层。
@Test func addingAMaskDoesNotBumpTheSchemaVersion() throws {
    var value = VideoEdit(duration: 10)
    #expect(value.schemaVersion == 5 && value.masks == nil)
    value.addMask(mask(1, 2))
    #expect(value.schemaVersion <= VideoEdit.writtenSchemaVersion)
    try value.validate(sourceDuration: 10)
    value.removeMask(id: value.maskList[0].id)
    #expect(value.masks == nil)
    try value.validate(sourceDuration: 10)
    // 开发期间存成 9 的工程照样打得开，归一化之后落回 6。
    var legacy = value; legacy.schemaVersion = 9
    try legacy.validate(sourceDuration: 10)
    legacy.normalizeSchemaVersion()
    #expect(legacy.schemaVersion == VideoEdit.writtenSchemaVersion)
    // 超出已知范围的仍然拒绝。
    var broken = value; broken.schemaVersion = 42
    #expect(throws: EditError.self) { try broken.validate(sourceDuration: 10) }
}

@Test func maskValidationRejectsBrokenGeometryAndOverlongSpans() {
    var value = VideoEdit(duration: 10)
    value.addMask(mask(1, 2))
    for broken in [{ (m: inout MaskSegment) in m.x = .nan }, { $0.width = 0 }, { $0.duration = -1 },
                   { $0.start = 9 }, { $0.darkness = 2 }, { $0.feather = .infinity }] as [(inout MaskSegment) -> Void] {
        var copy = value
        copy.updateMask(id: copy.maskList[0].id, broken)
        #expect(throws: EditError.self) { try copy.validate(sourceDuration: 10) }
    }
    // 关键帧时间乱序同样拒绝。
    var unordered = value
    unordered.updateMask(id: unordered.maskList[0].id) {
        $0.positionKeys = [MaskPointKeyframe(time: 1, x: 0.5, y: 0.5), MaskPointKeyframe(time: 0.2, x: 0.5, y: 0.5)]
    }
    #expect(throws: EditError.self) { try unordered.validate(sourceDuration: 10) }
}

@Test func oldProjectWithoutMaskKeyStillDecodes() throws {
    var original = VideoEdit(duration: 6)
    original.focuses = [FocusSegment(start: 0, duration: 2, x: 0.5, y: 0.5)]
    let data = try JSONEncoder().encode(original)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("\"masks\""), "没有遮罩的工程不该写出这个键")
    let loaded = try JSONDecoder().decode(VideoEdit.self, from: data)
    #expect(loaded.maskList.isEmpty && loaded == original)
}

@Test func weakMaskIsFlaggedSoExportCanWarn() {
    var value = VideoEdit(duration: 10)
    value.addMask(mask(1, 2))
    #expect(!value.hasWeakMask)
    value.updateMask(id: value.maskList[0].id) { $0.setAmount(5) }
    #expect(value.hasWeakMask)
    // 高亮不是用来挡内容的，弱强度不该报警。
    value.updateMask(id: value.maskList[0].id) { $0.kind = .highlight }
    #expect(!value.hasWeakMask)
}

@Test func maskNumbersFollowTimelineOrder() {
    var value = edit(clips: [(0, 20)])
    let late = mask(10, 2), early = mask(1, 2)
    value.addMask(late); value.addMask(early)
    let numbers = value.maskNumbers()
    #expect(numbers[early.id] == 1 && numbers[late.id] == 2)
    #expect(value.maskDisplayTitle(early, numbers: numbers) == "模糊 01")
}

/// 高亮跨过剪辑口时不能在每一段各自淡入淡出——那一刀在成片上是接严的，
/// 按段边界算淡入淡出会让画面在剪辑口闪一下。
@Test func highlightDoesNotBlinkAtEveryCut() throws {
    // 源 0…12，中间剪掉 5…8：一条 0…10 的高亮裂成成片 0…5 和 5…7 两段。
    var value = edit(clips: [(0, 5), (8, 4)])
    var spotlight = mask(0, 10, kind: .highlight)
    spotlight.fadeIn = 0.3; spotlight.fadeOut = 0.3
    value.addMask(spotlight)
    let spans = value.maskSpans().sorted { $0.start < $1.start }
    #expect(spans.count == 2, "夹具没有把高亮切成两段")
    // 剪辑口两侧各取几帧：强度必须都是满的，不能出现凹陷。
    for time in [4.7, 4.9, 4.99, 5.0, 5.05, 5.2, 5.4] {
        let alpha = try #require(value.maskState(spotlight, at: time, spans: spans)?.alpha)
        #expect(alpha > 0.999, "成片 \(time) 秒处强度掉到了 \(alpha)")
    }
    // 真正的两端仍然要淡入淡出。
    #expect((value.maskState(spotlight, at: 0.05, spans: spans)?.alpha ?? 1) < 0.6)
    #expect((value.maskState(spotlight, at: 6.95, spans: spans)?.alpha ?? 1) < 0.6)
    #expect((value.maskState(spotlight, at: 2, spans: spans)?.alpha ?? 0) > 0.999)
}

import Foundation
import Testing
@testable import EditingCore

/// 全屏卡段：在成片中间插入一段真实时长，画面冻结、声音静音。
/// 实现上它就是一条只有一帧可用素材的录制画面片段，靠合成器已有的"保持末帧"机制持续输出那一帧。
private func recording(_ duration: Double) -> VideoEdit {
    var edit = VideoEdit(duration: duration)
    edit.materializeLayers()
    return edit
}

@Test func insertingAHoldCardExtendsTheFinishedVideoAndFreezesTheFrame() throws {
    var edit = recording(10)
    let before = edit.duration
    let inserted8976 = edit.insertHoldCard(at: 4, duration: 3, sourceDuration: 10, text: "第 2 章")
    let card = try #require(inserted8976)
    // 成片变长了整整一段卡段。
    #expect(abs(edit.duration - (before + 3)) < 0.001, "成片变成了 \(edit.duration) 秒")
    let text = try #require(edit.text(id: card))
    #expect(text.layout == .fullscreen && text.timelineStart == 4 && abs(text.duration - 3) < 0.001)
    let frozen = try #require(edit.clips.first { $0.id == text.holdClipID })
    // 定格片段：时长是卡段长度，可用素材只有一帧，源时间就是插入点那一刻。
    #expect(frozen.timelineStart == 4 && abs(frozen.duration - 3) < 0.001)
    #expect(frozen.playableDuration < 0.05, "可用素材有 \(frozen.playableDuration) 秒，不是一帧")
    #expect(abs(frozen.sourceStart - 4) < 0.001, "冻结的是源 \(frozen.sourceStart) 秒，不是插入点那一帧")
    try edit.validate(sourceDuration: 10)

    // 插入点之后的画面整体后移。
    let after = edit.clips.filter { $0.id != frozen.id }.sorted { ($0.timelineStart ?? 0) < ($1.timelineStart ?? 0) }
    #expect(after.count == 2, "插入点在片段中间，应当先切成两块")
    #expect(abs((after[1].timelineStart ?? 0) - 7) < 0.001, "后半段落在 \(after[1].timelineStart ?? -1) 秒")
    #expect(abs(after[1].sourceStart - 4) < 0.001, "后半段的源起点被动了")
}

@Test func holdCardSilencesAudioBecauseItHasNoAudioClip() throws {
    var edit = recording(10)
    edit.systemClips = edit.clips.map { var copy = $0; copy.id = UUID(); return copy }
    edit.microphoneClips = edit.clips.map { var copy = $0; copy.id = UUID(); return copy }
    let inserted9299 = edit.insertHoldCard(at: 4, duration: 2, sourceDuration: 10)
    let card = try #require(inserted9299)
    let text = try #require(edit.text(id: card))
    let range = (text.timelineStart ?? 0)..<((text.timelineStart ?? 0) + text.duration)
    // 卡段区间里没有任何声音片段——静音是"那里本来就没有素材"，不是靠额外的静音逻辑。
    for clips in [edit.systemClips ?? [], edit.microphoneClips ?? []] {
        for clip in clips {
            let start = clip.timelineStart ?? 0, end = start + clip.duration
            #expect(end <= range.lowerBound + 0.001 || start >= range.upperBound - 0.001,
                    "卡段区间里还有声音：\(start)…\(end)")
        }
    }
}

@Test func overlaysKeepPointingAtTheSameContentAfterInsertingACard() throws {
    var edit = recording(10)
    // 源 6 秒处有一条遮罩、一句字幕。
    edit.addMask(MaskSegment(start: 6, duration: 1, x: 0.5, y: 0.5, width: 0.2, height: 0.1))
    edit.captionList = [CaptionCue(sourceStart: 6, sourceEnd: 7, text: "一句话")]
    let maskBefore = try #require(edit.maskSpans().first)
    #expect(abs(maskBefore.start - 6) < 0.001)

    let insertedA = edit.insertHoldCard(at: 3, duration: 2, sourceDuration: 10)
    #expect(insertedA != nil)
    // 遮罩与字幕存的是源时间，插入卡段之后它们的投影自动后移，源时间一个字都没改。
    #expect(edit.maskList[0].start == 6 && edit.captionList[0].sourceStart == 6)
    let maskAfter = try #require(edit.maskSpans().first)
    #expect(abs(maskAfter.start - 8) < 0.001, "遮罩投影到了 \(maskAfter.start) 秒，应当是 8")
    #expect(abs((edit.captionSpans().first?.start ?? 0) - 8) < 0.001)
    try edit.validate(sourceDuration: 10)
}

@Test func pinnedFocusesRippleAndSpanningOnesStretch() throws {
    var edit = recording(10)
    var early = FocusSegment(start: 0, duration: 1, x: 0.5, y: 0.5); early.timelineStart = 1
    var spanning = FocusSegment(start: 0, duration: 3, x: 0.5, y: 0.5); spanning.timelineStart = 3
    var late = FocusSegment(start: 0, duration: 1, x: 0.5, y: 0.5); late.timelineStart = 8
    edit.focuses = [early, spanning, late]
    let insertedB = edit.insertHoldCard(at: 4, duration: 2, sourceDuration: 10)
    #expect(insertedB != nil)
    let result = edit.focuses.sorted { ($0.timelineStart ?? 0) < ($1.timelineStart ?? 0) }
    #expect(result[0].timelineStart == 1, "插入点之前的镜头被动了")
    // 跨过插入点的镜头拉长同样的时长，插入点两侧的内容仍被它盖住。
    #expect(result[1].timelineStart == 3 && abs(result[1].duration - 5) < 0.001, "跨越的镜头变成了 \(result[1].duration) 秒")
    #expect(result[2].timelineStart == 10, "插入点之后的镜头落在 \(result[2].timelineStart ?? -1) 秒")
}

@Test func removingAHoldCardPutsEverythingBack() throws {
    var edit = recording(10)
    let original = edit
    let inserted568 = edit.insertHoldCard(at: 4, duration: 3, sourceDuration: 10)
    let card = try #require(inserted568)
    #expect(abs(edit.duration - 13) < 0.001)
    edit.removeHoldCard(textID: card)
    #expect(abs(edit.duration - 10) < 0.001, "删掉卡段之后成片是 \(edit.duration) 秒")
    #expect(edit.textList.isEmpty && edit.clips.allSatisfy { $0.title != "定格卡段" })
    // 片段被切成两块这件事留下了，但时间轴回到原样。
    let ends = edit.clips.map { ($0.timelineStart ?? 0) + $0.duration }.max() ?? 0
    #expect(abs(ends - (original.clips.map { ($0.timelineStart ?? 0) + $0.duration }.max() ?? 0)) < 0.001)
    try edit.validate(sourceDuration: 10)
}

@Test func changingTheCardDurationRipplesTheRest() throws {
    var edit = recording(10)
    let inserted9299 = edit.insertHoldCard(at: 4, duration: 2, sourceDuration: 10)
    let card = try #require(inserted9299)
    edit.setHoldCardDuration(textID: card, duration: 5)
    #expect(abs(edit.duration - 15) < 0.001, "成片变成了 \(edit.duration) 秒")
    #expect(abs((edit.text(id: card)?.duration ?? 0) - 5) < 0.001)
    let frozen = try #require(edit.clips.first { $0.id == edit.text(id: card)?.holdClipID })
    #expect(abs(frozen.duration - 5) < 0.001 && frozen.playableDuration < 0.05)
    try edit.validate(sourceDuration: 10)
    // 缩回去也一样。
    edit.setHoldCardDuration(textID: card, duration: 1)
    #expect(abs(edit.duration - 11) < 0.001)
    // 短于下限时被顶住，不会做出一个只看得到过渡的卡段。
    edit.setHoldCardDuration(textID: card, duration: 0.05)
    #expect(abs((edit.text(id: card)?.duration ?? 0) - VideoEdit.minimumHoldDuration) < 0.001)
}

@Test func togglingTheTimeInsertConvertsBothWaysWithoutLosingTheText() throws {
    var edit = recording(10)
    let made = edit.insertText(at: 3, duration: 2, sourceDuration: 10, preset: .title, text: "标题")
    let id = try #require(made)
    edit.updateText(id: id) { $0.layout = .fullscreen; $0.timelineStart = 3 }
    let turnedOn = edit.setHoldCard(textID: id, enabled: true, sourceDuration: 10)
    #expect(turnedOn)
    let card = try #require(edit.textList.first)
    #expect(card.holdClipID != nil && card.text == "标题" && abs(edit.duration - 12) < 0.001)
    try edit.validate(sourceDuration: 10)

    let turnedOff = edit.setHoldCard(textID: card.id, enabled: false, sourceDuration: 10)
    #expect(turnedOff)
    let kept = try #require(edit.text(id: card.id))
    #expect(kept.holdClipID == nil && kept.text == "标题", "撤掉插入时长把文字弄丢了")
    #expect(abs(edit.duration - 10) < 0.001, "撤掉之后成片是 \(edit.duration) 秒")
    try edit.validate(sourceDuration: 10)
}

@Test func stageTransformFadesThePictureDuringACardAndSplitsItOtherwise() throws {
    var edit = recording(10)
    let inserted568 = edit.insertHoldCard(at: 4, duration: 3, sourceDuration: 10)
    let card = try #require(inserted568)
    edit.updateText(id: card) { $0.layoutTransition = 0.5 }
    // 卡段正中：画面完全淡出、缩到 0.92。
    let middle = edit.stage(at: 5.5)
    #expect(middle.alpha < 0.01 && abs(middle.scale - TextSegment.holdScale) < 0.001, "卡段中间是 \(middle)")
    // 刚进卡段：还在过渡途中。
    let entering = edit.stage(at: 4.1)
    #expect(entering.alpha > 0.05 && entering.alpha < 0.99, "过渡中的不透明度是 \(entering.alpha)")
    // 卡段之外：完全不变，渲染时可以整段跳过。
    #expect(edit.stage(at: 2).isIdentity && edit.stage(at: 9).isIdentity)

    // 分屏：画面缩到半区并挪到一侧，文字盒在对面。
    var split = recording(10)
    var text = TextSegment(start: 0, duration: 6, text: "左分屏")
    text.layout = .splitLeft; text.timelineStart = 0; text.layoutTransition = 0.001
    split.addText(text)
    // 具体占多少由「画面占比」决定，这里只认两件事：缩了，并且去了文字对面那一栏。
    let left = split.stage(at: 3)
    #expect(left.scale == text.stageTarget.scale && left.scale < 1, "分屏时画面应当缩小，实际 \(left)")
    #expect(left.centerX > 0.5, "左分屏时画面应当去右半区，实际 \(left)")
    split.updateText(id: text.id) { $0.layout = .splitRight }
    let right = split.stage(at: 3)
    #expect(right.centerX < 0.5, "右分屏时画面应当去左半区，实际 \(right)")
    #expect(abs(left.scale - right.scale) < 0.0001)
    // 文字盒在画面的对面。
    #expect(text.textBoxFraction.minX < 0.2)
    var mirrored = text; mirrored.layout = .splitRight
    #expect(mirrored.textBoxFraction.maxX > 0.8)
}

@Test func insertingACardWhereThereIsNoPictureIsRefused() {
    var edit = VideoEdit(duration: 0)
    var head = VideoClip(sourceStart: 0, duration: 2); head.timelineStart = 0
    var tail = VideoClip(sourceStart: 4, duration: 2); tail.timelineStart = 4
    edit.clips = [head, tail]
    // 时间线空白处映射不出源时间，冻不出那一帧。
    let refused = edit.insertHoldCard(at: 3, duration: 2, sourceDuration: 6)
    #expect(refused == nil)
    #expect(edit.textList.isEmpty && edit.clips.count == 2)
}

/// 卡段文字与定格片段是一体的：拖片段的边、或把片段整个删掉之后，
/// 文字不能留在原地不动，也不能变成一段指向不存在片段的"幽灵卡段"。
@Test func cardTextFollowsItsFrozenClipAndSurvivesTheClipGoingAway() throws {
    var edit = recording(10)
    let inserted = edit.insertHoldCard(at: 4, duration: 3, sourceDuration: 10, text: "章节")
    let card = try #require(inserted)
    let clipID = try #require(edit.text(id: card)?.holdClipID)

    // 片段被拖短、又被拖到别处：文字跟着走。
    let number = try #require(edit.clips.firstIndex { $0.id == clipID })
    edit.clips[number].duration = 1.5
    edit.clips[number].timelineStart = 5
    edit.syncHoldCards()
    let moved = try #require(edit.text(id: card))
    #expect(moved.timelineStart == 5 && abs(moved.duration - 1.5) < 0.001, "文字停在 \(moved.timelineStart ?? -1) 秒、\(moved.duration) 秒长")
    #expect(moved.holdClipID == clipID)
    try edit.validate(sourceDuration: 10)

    // 片段被删掉：文字留下来，但不再自称卡段——否则面板上的"卡段时长"会指向一个不存在的片段。
    edit.clips.removeAll { $0.id == clipID }
    edit.syncHoldCards()
    let orphan = try #require(edit.text(id: card))
    #expect(orphan.holdClipID == nil && orphan.text == "章节")
    #expect(edit.holdCards.isEmpty)
    try edit.validate(sourceDuration: 10)
}

/// 镜头是绑在片段 ID 上的，而定格片段是新造的一条——不认亲就会在卡段两端各硬跳一次：
/// 1.8× 推近到卡段第一帧猛地弹回 1.0×，卡段一结束又弹回去。
/// 另一半是时序：被切开的半段镜头带着运镜包络长度，拉长时只加时长不加包络长度，
/// 校验直接判无效，插完卡段保存 / 播放 / 导出全都报"内容无效"。
@Test func cameraKeepsItsZoomAcrossACardAndTheProjectStaysValid() throws {
    for follows in [nil, false, true] as [Bool?] {
        var edit = VideoEdit(duration: 10)
        var zoom = FocusSegment(start: 3, duration: 3, x: 0.4, y: 0.6, scale: 1.8)
        zoom.easeIn = 0.6; zoom.easeOut = 0.7; zoom.followsTimeline = follows
        edit.focuses = [zoom]
        edit.prepareLayerEditing(camera: false, system: false, microphone: false)
        let inserted = edit.insertHoldCard(at: 4, duration: 3, sourceDuration: 10)
        #expect(inserted != nil, "followsTimeline=\(String(describing: follows)) 时没插进去")
        // 保存 / 播放 / 导出都要先过校验。
        try edit.validate(sourceDuration: 10)
        // 镜头在卡段内外连续：卡段是把画面冻住，不是把镜头也一起丢掉。
        for time in [3.99, 4.01, 5.5, 6.9, 7.01] {
            let scale = SceneEvaluator.focus(edit: edit, time: time).scale
            #expect(abs(scale - 1.8) < 0.05, "followsTimeline=\(String(describing: follows))，\(time) 秒处推近是 \(scale)")
        }
    }
}

/// 自动镜头烘焙出来的运镜路径不能因为插了卡段就被清空——那等于把用户看到的运镜换成另一套。
@Test func insertingACardKeepsABakedCameraPathIntact() throws {
    var edit = VideoEdit(duration: 10)
    var zoom = FocusSegment(start: 2, duration: 5, x: 0.5, y: 0.5, scale: 2)
    zoom.automatic = true
    zoom.path = [FocusKeyframe(time: 0, x: 0.3, y: 0.3, scale: 2, move: 0),
                 FocusKeyframe(time: 5, x: 0.7, y: 0.7, scale: 2, move: 0)]
    edit.focuses = [zoom]
    edit.prepareLayerEditing(camera: false, system: false, microphone: false)
    #expect(edit.focuses.allSatisfy { $0.path != nil }, "夹具本身就没有烘焙路径")
    let inserted = edit.insertHoldCard(at: 4, duration: 2, sourceDuration: 10)
    #expect(inserted != nil)
    // 编辑器每次提交都会跑一遍，插卡段这一次提交自己就会走到。
    edit.constrainTimelineFocuses()
    try edit.validate(sourceDuration: 10)
    // 被卡段切开的那两半都要完好：跨过卡段的那一半最容易被判成"跨出了原片段"，
    // 于是关联被解除、烘焙路径被清空，用户看到的运镜换成了另一套。
    #expect(edit.focuses.count == 2)
    #expect(edit.focuses.allSatisfy { $0.path != nil }, "插卡段把烘焙好的运镜路径清空了")
    #expect(edit.focuses.allSatisfy { $0.targetClipID != nil && $0.followsTimeline == nil }, "镜头被改成了智能跟随")
}

/// 在片尾附近插卡段：卡段文字钉在成片时间上，源域上必然越界。
/// 按源域校验的话整笔编辑会被回滚，用户只看到一句"内容无效"。
@Test func insertingACardNearTheEndOfTheRecordingStillValidates() throws {
    for anchor in [9.0, 9.9, 10.0] {
        var edit = recording(10)
        let inserted = edit.insertHoldCard(at: anchor, duration: 3, sourceDuration: 10, text: "谢谢观看")
        let card = try #require(inserted, "\(anchor) 秒处没插进去")
        try edit.validate(sourceDuration: 10)
        let text = try #require(edit.text(id: card))
        #expect(text.timelineStart != nil && abs(text.duration - 3) < 0.001)
        #expect(abs(edit.duration - 13) < 0.001, "成片变成了 \(edit.duration) 秒")
    }
    // 卡段比整段录制还长也一样得立得住。
    var short = recording(2)
    let long = short.insertHoldCard(at: 1, duration: 8, sourceDuration: 2)
    #expect(long != nil)
    try short.validate(sourceDuration: 2)
}

/// 在时间线上拖卡段那一块：拖右缘等于改卡段时长，绝不能把定格弄丢。
/// 按普通片段那套重算 `mediaDuration`，定格就变回正常播放的录屏，而声音早被挪空了。
@Test func draggingTheCardBlockChangesItsLengthWithoutBreakingTheFreeze() throws {
    var edit = recording(10)
    let inserted = edit.insertHoldCard(at: 4, duration: 3, sourceDuration: 10)
    let card = try #require(inserted)
    let clipID = try #require(edit.text(id: card)?.holdClipID)
    func frozen() throws -> VideoClip { try #require(edit.clips.first { $0.id == clipID }) }

    edit.dragMedia(.screen, id: clipID, edge: .trailing, delta: 1, sourceDuration: 10)
    var clip = try frozen()
    #expect(clip.playableDuration < 0.05, "拖完右缘可用素材有 \(clip.playableDuration) 秒，定格没了")
    #expect(abs(clip.duration - 4) < 0.001 && abs((edit.text(id: card)?.duration ?? 0) - 4) < 0.001)
    #expect(abs(edit.duration - 14) < 0.001, "后面的内容没跟着挪，成片是 \(edit.duration) 秒")
    try edit.validate(sourceDuration: 10)

    // 手抖一点点也不行。
    edit.dragMedia(.screen, id: clipID, edge: .trailing, delta: 0.01, sourceDuration: 10)
    #expect(try frozen().playableDuration < 0.05)
    // 左缘没有对应语义：宁可拖不动，也不能把定格帧整体挪走。
    let before = try frozen()
    edit.dragMedia(.screen, id: clipID, edge: .leading, delta: -1, sourceDuration: 10)
    clip = try frozen()
    #expect(clip.sourceStart == before.sourceStart && clip.duration == before.duration)
    #expect(clip.playableDuration < 0.05)
    try edit.validate(sourceDuration: 10)
}

/// 卡段那一块切不得：切完两半各自还是定格，可文字只认得其中一半，另一半就成了没人管的空定格。
@Test func theCardBlockRefusesToBeSplit() throws {
    var edit = recording(10)
    let inserted = edit.insertHoldCard(at: 4, duration: 3, sourceDuration: 10)
    let card = try #require(inserted)
    let clipID = try #require(edit.text(id: card)?.holdClipID)
    let before = edit
    #expect(edit.splitMedia(.screen, id: clipID, at: 5.5) == nil)
    #expect(edit == before, "卡段被切开了")
}

/// 人像画中画也要跟着冻住：只给画面轨加定格的话，卡段这一段摄像头轨是空的，
/// 画中画会在卡段开始时整个消失、结束时再弹回来，而不是随画面一起淡出。
@Test func theCameraFreezesAlongWithThePictureInsteadOfDisappearing() throws {
    var edit = recording(10)
    let inserted = edit.insertHoldCard(at: 4, duration: 3, sourceDuration: 10)
    #expect(inserted != nil)
    try edit.validate(sourceDuration: 10)
    let camera = edit.resolvedMedia(.camera)
    // 卡段这一段摄像头轨不能是空的。
    for time in [4.05, 5.5, 6.9] {
        let covering = camera.first { time >= ($0.timelineStart ?? 0) && time < ($0.timelineStart ?? 0) + $0.duration }
        let clip = try #require(covering, "\(time) 秒处摄像头轨是空的，画中画会消失")
        #expect(clip.playableDuration < 0.05, "\(time) 秒处人像在照常播放，没有冻住")
    }
    // 声音相反：卡段是静音的。
    for role in [TimelineMedia.system, .microphone] {
        let audio = edit.resolvedMedia(role)
        #expect(!audio.contains { 5.5 >= ($0.timelineStart ?? 0) && 5.5 < ($0.timelineStart ?? 0) + $0.duration }, "\(role) 在卡段里还在响")
    }
}

/// 播放头停在卡段上时新建的文字与遮罩要钉在成片时间上。
/// 定格片段的源区间和它后面那条正片片段是同一段，按源域建的话会在卡段和正片上各画一次。
@Test func overlaysCreatedOnACardArePinnedSoTheyDoNotAppearTwice() throws {
    var edit = recording(10)
    let inserted = edit.insertHoldCard(at: 4, duration: 3, sourceDuration: 10)
    #expect(inserted != nil)
    let addedText = edit.insertText(at: 5.5, duration: 1, sourceDuration: 10, text: "注解")
    let textID = try #require(addedText)
    let addedMask = edit.insertMask(at: 5.5, duration: 1, sourceDuration: 10)
    let maskID = try #require(addedMask)
    try edit.validate(sourceDuration: 10)

    #expect(edit.text(id: textID)?.timelineStart != nil && edit.mask(id: maskID)?.timelineStart != nil)
    #expect(edit.textSpans().filter { $0.textID == textID }.count == 1, "这段文字画了不止一次")
    #expect(edit.maskSpans().filter { $0.maskID == maskID }.count == 1, "这条遮罩画了不止一次")
    #expect(edit.activeTexts(at: 5.8).contains { $0.id == textID })
    #expect(!edit.activeTexts(at: 8.8).contains { $0.id == textID }, "卡段之后又画了一次")
}

/// 插入点贴着某条声音块的边缘、切不动的时候：宁可把那不到 0.25 秒的一小截裁掉，
/// 也不能把整块平移——平移会让这条轨相对画面错开同样的时间，从此对不上口型。
@Test func aTrackThatCannotBeCutLosesASliverInsteadOfDriftingOutOfSync() throws {
    var edit = recording(10)
    // 麦克风轨在 3.9 秒处有一刀，卡段插在 4 秒：这一块只露头 0.1 秒，短于最小片段时长，切不动。
    edit.microphoneClips = [{ var clip = VideoClip(sourceStart: 0, duration: 3.9); clip.timelineStart = 0; return clip }(),
                            { var clip = VideoClip(sourceStart: 3.9, duration: 6.1); clip.timelineStart = 3.9; return clip }()]
    let inserted = edit.insertHoldCard(at: 4, duration: 3, sourceDuration: 10)
    #expect(inserted != nil)
    try edit.validate(sourceDuration: 10)
    // 卡段之后每一块麦克风片段的"成片时间 − 源时间"仍然与画面一致：没有整体错位。
    for clip in edit.resolvedMedia(.microphone) where (clip.timelineStart ?? 0) > 7 - 0.001 {
        let drift = (clip.timelineStart ?? 0) - 3 - clip.sourceStart
        #expect(abs(drift) < 0.001, "麦克风相对画面错开了 \(drift) 秒")
    }
    // 卡段里是静音的。
    #expect(!edit.resolvedMedia(.microphone).contains { 5.5 >= ($0.timelineStart ?? 0) && 5.5 < ($0.timelineStart ?? 0) + $0.duration })
}

/// 加一段卡段不该把时间线拆得到处都是行：切开的两半要回到同一行，
/// 定格片段插在它冻结自的那一块旁边。否则一条画面轨会变成
/// "录制画面 01 / 定格卡段 / 录制画面 02" 三行，声音轨也各裂一行。
@Test func insertingACardKeepsEachTrackOnOneRow() throws {
    var edit = recording(20)
    edit.systemClips = edit.clips.map { var copy = $0; copy.id = UUID(); return copy }
    edit.microphoneClips = edit.clips.map { var copy = $0; copy.id = UUID(); return copy }
    edit.cameraClips = edit.clips.map { var copy = $0; copy.id = UUID(); return copy }
    let rowsBefore = edit.timelineRows.count

    let inserted = edit.insertHoldCard(at: 8, duration: 3, sourceDuration: 20, text: "第 2 章")
    let card = try #require(inserted)
    try edit.validate(sourceDuration: 20)

    let rows = edit.timelineRows
    // 只多出文字那一行：四条轨各自切成两半 + 一条定格片段 + 一条人像定格，全都回到了原来的行里。
    #expect(rows.count == rowsBefore + 1, "时间线从 \(rowsBefore) 行变成了 \(rows.count) 行：\(rows.map(\.count))")
    let clipID = try #require(edit.text(id: card)?.holdClipID)
    let screenRow = try #require(rows.first { $0.contains(clipID) })
    // 画面那一行上是"原块 + 定格 + 尾块"三块，按时间排好。
    #expect(screenRow.count == 3, "画面行上有 \(screenRow.count) 块")
    let starts = screenRow.compactMap { id in edit.clips.first { $0.id == id }?.timelineStart }
    #expect(starts.count == 3 && Set(starts).count == 3)
    // 声音也各自并回一行。
    for role in [TimelineMedia.system, .microphone] {
        let ids = Set(edit.mediaClips(role).map(\.id))
        let row = try #require(rows.first { !$0.filter(ids.contains).isEmpty })
        #expect(row.filter(ids.contains).count == 2, "\(role) 裂成了 \(rows.filter { !$0.filter(ids.contains).isEmpty }.count) 行")
    }
}

/// 卡段时长的卡尺撤掉之后，时间线是唯一入口：拖文字块的右缘必须真的改卡段长度
/// （文字与定格片段一起变、后面的内容一起挪），而不是只改 TextSegment.duration 然后被同步掰回去。
@Test func draggingTheTrailingEdgeOfACardTextChangesTheCardItself() throws {
    var edit = recording(10)
    let inserted = edit.insertHoldCard(at: 4, duration: 3, sourceDuration: 10, text: "第二章")
    let card = try #require(inserted)
    let clipID = try #require(edit.text(id: card)?.holdClipID)
    let tail = try #require(edit.clips.first { ($0.timelineStart ?? 0) > 4.5 })
    let tailStart = try #require(tail.timelineStart)

    edit.dragText(id: card, edge: .trailing, delta: 2, sourceDuration: 10)
    edit.syncHoldCards()
    let clip = try #require(edit.clips.first { $0.id == clipID })
    #expect(abs(clip.duration - 5) < 0.0001, "定格片段没跟着变长，实际 \(clip.duration)")
    #expect(abs((edit.text(id: card)?.duration ?? 0) - 5) < 0.0001)
    #expect((edit.clips.first { $0.id == tail.id }?.timelineStart ?? 0) > tailStart + 1.9, "后面的内容没有跟着往后挪")
}

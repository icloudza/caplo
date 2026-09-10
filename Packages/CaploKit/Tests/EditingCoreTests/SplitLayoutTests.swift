import CoreGraphics
import Foundation
import Testing
@testable import EditingCore

/// 左右分屏与全屏的版式几何：两栏的宽度由「画面占比」决定、画面与文字永远互补不重叠，
/// 全屏无论插不插入时长都让画面退场（否则它和「叠加」看不出区别）。
private func text(_ layout: TextSegment.Layout, ratio: Double = 0.5, gap: Double = 48) -> TextSegment {
    var value = TextPreset.title.segment(start: 0, duration: 4)
    // 得有字：空文字按约定不改变画面。
    value.text = "第 2 章"
    value.layout = layout; value.splitRatio = ratio; value.splitGap = gap
    return value
}

@Test(arguments: [0.25, 0.4, 0.5, 0.65, 0.75]) func splitRatioMovesTheDivideAndTheTwoColumnsStayComplementary(ratio: Double) throws {
    for layout in [TextSegment.Layout.splitLeft, .splitRight] {
        let value = text(layout, ratio: ratio)
        let columns = value.splitColumns
        let picture = columns.picture.upperBound - columns.picture.lowerBound
        let box = value.textBoxFraction
        let pad = TextSegment.stagePadding, gap = 48.0 / 960

        // 两栏加上间距与两侧留白，正好铺满画布：没有重叠也没有多出来的缝。
        #expect(abs(picture + box.width + gap + 2 * pad - 1) < 0.0001, "两栏合计 \(picture + box.width)，占比 \(ratio)")
        #expect(abs(picture / (picture + box.width) - ratio) < 0.0001, "画面占了 \(picture / (picture + box.width))")
        // 文字在左，画面就在右；两栏之间隔着间距。
        if layout == .splitLeft {
            #expect(abs(box.minX - pad) < 0.0001 && abs(columns.picture.upperBound - (1 - pad)) < 0.0001)
            #expect(abs(columns.picture.lowerBound - box.maxX - gap) < 0.0001)
        } else {
            #expect(abs(columns.picture.lowerBound - pad) < 0.0001 && abs(box.maxX - (1 - pad)) < 0.0001)
            #expect(abs(box.minX - columns.picture.upperBound - gap) < 0.0001)
        }
        // 画面层的相似变换就落在画面那一栏上。
        let target = value.stageTarget
        #expect(target.split && abs(target.scale - picture) < 0.0001)
        #expect(abs(target.centerX - (columns.picture.lowerBound + columns.picture.upperBound) / 2) < 0.0001)
        #expect(abs(target.alpha - 1) < 0.0001, "分屏不该把画面淡掉")
    }
}

@Test func splitRatioIsClampedAndTheGapNeverEatsTheColumns() {
    // 越界的占比按等分处理，不会算出负宽度的栏。
    for broken in [Double.nan, -1, 0, 5] {
        var value = text(.splitRight); value.splitRatio = broken
        let columns = value.splitColumns
        #expect(columns.picture.upperBound > columns.picture.lowerBound)
        #expect(value.textBoxFraction.width > 0)
        #expect(!value.isValid, "越界的占比应当被校验拒绝")
    }
    // 间距拉到最大时两栏仍然各有宽度。
    var wide = text(.splitLeft, ratio: 0.75, gap: 240)
    #expect(wide.textBoxFraction.width > 0.02 && wide.stageTarget.scale > 0.02)
    #expect(wide.isValid)
    wide.splitRatio = 0.5
    #expect(wide.isValid)
}

/// 「全屏」以前只换了个文字盒，画面纹丝不动——用户看不出它和「叠加」有什么区别。
/// 现在全屏一律让画面缩一点并退场，「插入时长」只决定成片会不会因此变长。
@Test func fullscreenRetiresThePictureWhetherOrNotItInsertsTime() throws {
    var edit = VideoEdit(duration: 10)
    edit.materializeLayers()
    var value = text(.fullscreen)
    value.timelineStart = 3
    value.duration = 4
    value.layoutTransition = 0.4
    edit.addText(value)
    // 版式完全生效的时刻：画面已经退场。
    let middle = edit.stage(at: 5)
    #expect(middle.alpha < 0.001 && abs(middle.scale - TextSegment.holdScale) < 0.001)
    #expect(!middle.split, "全屏不是分屏，画中画不该被摘出来")
    // 叠加相反，画面一动不动。
    edit.updateText(id: value.id) { $0.layout = .overlay }
    #expect(edit.stage(at: 5).isIdentity)
    // 两端的过渡仍然是连续的。
    edit.updateText(id: value.id) { $0.layout = .fullscreen }
    let entering = edit.stage(at: 3.2)
    #expect(entering.alpha > 0.05 && entering.alpha < 0.95, "进场中途 alpha 是 \(entering.alpha)")
}

/// 浮在录屏之上的画中画在分屏时被摘出来单独摆：不跟着画面缩，落在画面那一栏里。
/// 侧边 / 在后 / 分屏 / 人像全屏的人像是画面构图的一部分，不摘。
@Test func onlyTheFloatingPortraitIsLiftedOutOfTheShrunkenPicture() {
    var layout = CameraLayout()
    #expect(layout.isFloatingPortrait)
    for mode in [CameraLayout.Mode.sideLeading, .behindTrailing, .splitLeading, .cameraFull] {
        var other = layout; other.mode = mode
        #expect(!other.isFloatingPortrait, "\(mode) 不该被摘出来")
    }
    layout.belowScreen = true
    #expect(!layout.isFloatingPortrait, "垫在录屏下面的画中画摘出来就跑到画面上面去了")

    // 摆进画面那一栏：默认的圆形人像在等分分屏下大小基本不变，位置落在栏内。
    layout = CameraLayout(); layout.size = 0.24; layout.x = 1; layout.y = 1
    let canvas = CGSize(width: 1920, height: 1080)
    // 等分分屏时画面层是整幅画布的 0.415 倍，居中。
    let column = CGRect(x: 1920 * 0.5335, y: 1080 * 0.2925, width: 1920 * 0.415, height: 1080 * 0.415)
    let full = layout.rect(in: canvas), inside = layout.rect(in: canvas, region: column)
    #expect(inside.width > full.width * 0.95, "等分分屏就把人像从 \(full.width) 收到了 \(inside.width)")
    #expect(inside.width <= full.width + 0.001, "摘出来的人像不该比原来还大")
    #expect(column.insetBy(dx: -1, dy: -1).contains(inside), "人像 \(inside) 跑出了画面栏 \(column)")
    // 栏被拉得很窄时才收，收完也仍然在栏内、不超过栏的六成。
    let narrow = CGRect(x: 0, y: 0, width: 300, height: 240)
    let squeezed = layout.rect(in: canvas, region: narrow)
    #expect(squeezed.width < full.width && squeezed.height <= narrow.height * 0.6 + 0.001)
    #expect(narrow.insetBy(dx: -1, dy: -1).contains(squeezed))
}

/// 每给文字层加一个新参数，之前存下来的工程就少一个键。编译器合成的解码器**不认默认值**，
/// 缺一个键就抛 keyNotFound、整份工程作废（用户看到的是一句"编辑数据版本不支持或内容无效"）。
@Test func textDecodesFromAProjectSavedBeforeTheNewerFieldsExisted() throws {
    // 只有最早那一版写出去的键。
    let legacy = Data("""
    {"id":"5E4A0C36-0C1F-4F1A-9C4E-1B2D3E4F5061","start":2,"duration":4,"text":"产品演示",
     "size":96,"weight":700,"family":"system","italic":false,"alignment":"center",
     "lineHeight":1.15,"tracking":0,"x":0.5,"y":0.5,"maxWidth":0.8,
     "color":"auto","opacity":1,"plate":false,"plateColor":"ink","plateOpacity":0.55,
     "platePadding":16,"plateRadius":8,"plateFull":false,"shadow":false,"shadowOpacity":0.45,
     "shadowBlur":18,"shadowOffset":6,"enterKind":"fade","enterDuration":0.4,
     "exitKind":"fade","exitDuration":0.35,"enabled":true}
    """.utf8)
    let value = try JSONDecoder().decode(TextSegment.self, from: legacy)
    #expect(value.text == "产品演示" && value.start == 2 && value.duration == 4)
    // 缺的键落到默认值上，而不是让整份工程作废。
    #expect(value.layout == .overlay && value.splitRatio == TextSegment.defaultSplitRatio
            && value.splitGap == TextSegment.defaultSplitGap)
    #expect(abs(value.layoutTransition - 0.35) < 0.0001 && value.holdClipID == nil)
    #expect(value.isValid)

    // 连最短的一份（只有起止时间）也要解得出来。
    let minimal = try JSONDecoder().decode(TextSegment.self, from: Data("{\"start\":0,\"duration\":3}".utf8))
    #expect(minimal.duration == 3 && minimal.text.isEmpty && minimal.enabled)
    // 起止时间仍然是必需的：真正残缺的数据要拒收，不能当成一段默认文字放进去。
    #expect(throws: (any Error).self) { try JSONDecoder().decode(TextSegment.self, from: Data("{\"text\":\"x\"}".utf8)) }

    // 编码 → 解码仍然一字不差。
    var round = TextSegment(start: 1, duration: 5, text: "分屏")
    round.layout = .splitLeft; round.splitRatio = 0.7; round.splitGap = 96; round.holdClipID = UUID()
    round.timelineStart = 1; round.title = "第一段"; round.preset = "标题"
    #expect(try JSONDecoder().decode(TextSegment.self, from: JSONEncoder().encode(round)) == round)
}

/// 遮罩与字幕同理：手写的解码器必须与合成的编码器一一对应（键名写错就会在这里露馅），
/// 缺键要落到默认值上，遮罩强度缺失时按 fail-closed 兜到最强像素化。
@Test func masksAndCaptionsAlsoSurviveMissingKeysAndRoundTrip() throws {
    var mask = MaskSegment(start: 1, duration: 2, x: 0.4, y: 0.6, width: 0.3, height: 0.2, kind: .highlight, effect: .blur, amount: 24)
    mask.positionKeys = [MaskPointKeyframe(time: 0, x: 0.1, y: 0.2)]
    mask.title = "密钥"; mask.timelineStart = 3; mask.cornerRadius = 12; mask.feather = 6
    #expect(try JSONDecoder().decode(MaskSegment.self, from: JSONEncoder().encode(mask)) == mask)
    let bare = try JSONDecoder().decode(MaskSegment.self, from: Data(
        "{\"start\":1,\"duration\":2,\"x\":0.5,\"y\":0.5,\"width\":0.2,\"height\":0.1}".utf8))
    #expect(bare.kind == .sensitive && bare.enabled && bare.darkness == 0.55)
    // 强度缺失 = 解不出来，按最强像素化兜底，绝不能变成"不打码"。
    #expect(bare.effect == .pixelate && bare.amount == MaskSegment.amountRange.upperBound)

    var cue = CaptionCue(sourceStart: 1, sourceEnd: 2.5, text: "你好", words: [CaptionWord(start: 1, end: 2, text: "你好")])
    cue.locked = true; cue.lead = 0.2; cue.timelineStart = 4
    #expect(try JSONDecoder().decode(CaptionCue.self, from: JSONEncoder().encode(cue)) == cue)
    let bareCue = try JSONDecoder().decode(CaptionCue.self, from: Data("{\"sourceStart\":0,\"sourceEnd\":1}".utf8))
    #expect(bareCue.enabled && !bareCue.locked && bareCue.text.isEmpty)

    var style = CaptionStyle()
    style.highlight = .pill; style.burnIn = false; style.size = 60; style.minHold = 2
    #expect(try JSONDecoder().decode(CaptionStyle.self, from: JSONEncoder().encode(style)) == style)
    let bareStyle = try JSONDecoder().decode(CaptionStyle.self, from: Data("{}".utf8))
    #expect(bareStyle == CaptionStyle())
}

/// 点一下预设只该换排版、外观与进出动画。文本、时间、版式、分屏参数、卡段归属、名字都要留着——
/// 这条判定是"反过来"写的（列举预设要改什么），因为正着写每加一个新参数就漏一次，
/// 而且漏了不报错，只表现为"刚调好的参数被点一下预设打回默认"。
@Test func applyingAPresetOnlyChangesTypographyAndLeavesTheLayoutAlone() throws {
    var value = TextSegment(start: 2, duration: 5, text: "产品演示")
    value.timelineStart = 7; value.title = "第三段"
    value.layout = .splitRight; value.splitRatio = 0.7; value.splitGap = 96; value.layoutTransition = 0.8
    value.enabled = false
    value.size = 30; value.weight = 400; value.alignment = .leading; value.shadow = false

    let applied = TextPreset.title.applied(to: value)
    // 保留的那一半。
    #expect(applied.id == value.id && applied.text == "产品演示" && applied.title == "第三段")
    #expect(applied.start == 2 && applied.duration == 5 && applied.timelineStart == 7)
    #expect(applied.layout == .splitRight && applied.splitRatio == 0.7 && applied.splitGap == 96)
    #expect(abs(applied.layoutTransition - 0.8) < 0.0001)
    #expect(applied.enabled == false)
    // 换掉的那一半。
    let reference = TextPreset.title.segment(start: 2, duration: 5)
    #expect(applied.size == reference.size && applied.weight == reference.weight)
    #expect(applied.alignment == reference.alignment && applied.shadow == reference.shadow)
    #expect(applied.enterKind == reference.enterKind && applied.preset == reference.preset)
    #expect(TextPreset.matching(applied) == .title, "套完预设之后面板里那一格应当选中")
    #expect(applied.isValid)

    // 卡段的归属也要留着：丢了的话那段定格片段就没人认领，成片里留下一段空白的定格。
    var card = TextSegment(start: 0, duration: 3, text: "第 2 章")
    card.layout = .fullscreen; card.timelineStart = 4; card.holdClipID = UUID()
    let recast = TextPreset.bigNumber.applied(to: card)
    #expect(recast.holdClipID == card.holdClipID && recast.layout == .fullscreen && recast.timelineStart == 4)
    #expect(recast.isValid && recast.size == TextPreset.bigNumber.segment(start: 0, duration: 3).size)

    // 每个预设都只动这些字段：把排版与外观抹平之后，剩下的应当与原件一模一样。
    for preset in TextPreset.allCases {
        var stripped = preset.applied(to: value)
        stripped.preset = value.preset
        stripped.size = value.size; stripped.weight = value.weight; stripped.family = value.family
        stripped.alignment = value.alignment
        stripped.lineHeight = value.lineHeight; stripped.tracking = value.tracking
        stripped.x = value.x; stripped.y = value.y; stripped.maxWidth = value.maxWidth
        stripped.color = value.color; stripped.opacity = value.opacity
        stripped.plate = value.plate; stripped.plateColor = value.plateColor; stripped.plateOpacity = value.plateOpacity
        stripped.platePadding = value.platePadding; stripped.plateRadius = value.plateRadius; stripped.plateFull = value.plateFull
        stripped.shadow = value.shadow; stripped.shadowOpacity = value.shadowOpacity
        stripped.shadowBlur = value.shadowBlur; stripped.shadowOffset = value.shadowOffset
        stripped.enterKind = value.enterKind; stripped.enterDuration = value.enterDuration
        stripped.exitKind = value.exitKind; stripped.exitDuration = value.exitDuration
        #expect(stripped == value, "\(preset.name) 动了排版与外观之外的东西")
    }
}

/// 两段全屏文字首尾交叠时不能闪：单纯"后加的压前面的"会让画面在一帧里从全黑弹回满亮度，
/// 因为后一段刚起步、版式还没生效。取生效得更彻底的那一段才连续。
@Test func twoOverlappingStageTextsHandOverWithoutFlashing() throws {
    var edit = VideoEdit(duration: 20)
    edit.materializeLayers()
    for (start, body) in [(2.0, "第一章"), (5.0, "第二章")] {
        var value = TextSegment(start: 0, duration: 5, text: body)
        value.layout = .fullscreen; value.timelineStart = start
        edit.addText(value)
    }
    // 交叠区间 5…7 秒：两段都已经完全生效，画面得一直压着，不能因为"后一段刚起步"就弹回来。
    for time in [5.05, 5.5, 6.0, 6.5, 6.95] {
        #expect(edit.stage(at: time).alpha < 0.02, "成片 \(time) 秒处画面亮度弹回了 \(edit.stage(at: time).alpha)")
    }
    // 全程连续：步长 5 毫秒，比一帧还密，一帧之内不许跳。
    var previous: StageTransform?
    for step in 0...1000 {
        let time = 1.5 + Double(step) * 0.005
        let now = edit.stage(at: time)
        if let previous {
            #expect(abs(now.alpha - previous.alpha) < 0.1, "成片 \(time) 秒处亮度一帧之内跳了 \(now.alpha - previous.alpha)")
            #expect(abs(now.scale - previous.scale) < 0.1, "成片 \(time) 秒处尺寸一帧之内跳了 \(now.scale - previous.scale)")
        }
        previous = now
    }
    // 两段都过完之后画面回来。
    #expect(edit.stage(at: 12).isIdentity)
}

/// 空文字不该改变画面：新建一段全屏文字、还没打字，画面不能整段黑掉。
@Test func anEmptyStageTextLeavesThePictureAlone() throws {
    var edit = VideoEdit(duration: 10)
    edit.materializeLayers()
    var value = TextSegment(start: 0, duration: 4, text: "")
    value.layout = .fullscreen; value.timelineStart = 2; value.layoutTransition = 0.3
    edit.addText(value)
    #expect(edit.stage(at: 4).isIdentity, "空文字把画面抹掉了，可一个字都没画")
    #expect(edit.activeTexts(at: 4).isEmpty)
    // 打上字之后才生效。
    edit.updateText(id: value.id) { $0.text = "第 2 章" }
    #expect(edit.stage(at: 4).alpha < 0.001)
    // 分屏同理。
    edit.updateText(id: value.id) { $0.layout = .splitLeft; $0.text = "" }
    #expect(edit.stage(at: 4).isIdentity)
}

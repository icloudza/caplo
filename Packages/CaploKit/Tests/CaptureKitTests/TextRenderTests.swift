import AppKit
import CoreGraphics
import CoreImage
import Foundation
import Testing
import EditingCore
@testable import RenderKit

/// 文字渲染的契约：尺寸按 1080 参考高度书写、换到任何输出分辨率几何都等比一致，
/// 动画只改位移缩放与不透明度而不重排版，打字机揭字时版面一动不动，空文字不画。
private let textSpace = CGColorSpace(name: CGColorSpace.sRGB)!

private struct Shot {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    func alpha(x: Int, y: Int) -> Int { Int(bytes[(y * width + x) * 4 + 3]) }
    /// 有内容（alpha 明显不为零）的像素的外接矩形，位图坐标（自上而下）。
    var box: CGRect? {
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where alpha(x: x, y: y) > 24 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: Double(minX), y: Double(minY), width: Double(maxX - minX + 1), height: Double(maxY - minY + 1))
    }
    var coverage: Int { (0..<(width * height)).reduce(0) { $0 + (Int(bytes[$1 * 4 + 3]) > 24 ? 1 : 0) } }
}

private func shot(_ image: CIImage?, size: CGSize) -> Shot {
    let width = Int(size.width), height = Int(size.height)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    if let image {
        CIContext().render(image, toBitmap: &bytes, rowBytes: width * 4,
                           bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: textSpace)
    }
    return Shot(bytes: bytes, width: width, height: height)
}

private func state(_ segment: TextSegment, alpha: Double = 1, scale: Double = 1, offset: Double = 0, revealed: Int? = nil) -> TextState {
    TextState(id: segment.id, segment: segment,
              animation: TextAnimationState(alpha: alpha, offset: offset, scale: scale, reveal: revealed == nil ? 1 : 0.5),
              revealedCount: revealed ?? segment.text.count)
}

@Test func textGeometryScalesExactlyWithOutputResolution() throws {
    // 同一段文字在 720p / 1080p / 4K 下，包围盒相对画布的位置与大小必须一致。
    var segment = TextPreset.title.segment(start: 0, duration: 3)
    segment.text = "产品演示"; segment.shadow = false
    let renderer = TextRenderer()
    var relative: [CGRect] = []
    for size in [CGSize(width: 1280, height: 720), CGSize(width: 1920, height: 1080), CGSize(width: 3840, height: 2160)] {
        let frame = try #require(renderer.textFrame(for: state(segment), canvas: size, lightBackground: false))
        relative.append(CGRect(x: frame.minX / size.width, y: frame.minY / size.height,
                               width: frame.width / size.width, height: frame.height / size.height))
    }
    for candidate in relative.dropFirst() {
        #expect(abs(candidate.minX - relative[0].minX) < 0.004 && abs(candidate.width - relative[0].width) < 0.004,
                "横向 \(candidate) 与 \(relative[0]) 不一致")
        #expect(abs(candidate.minY - relative[0].minY) < 0.004 && abs(candidate.height - relative[0].height) < 0.006,
                "纵向 \(candidate) 与 \(relative[0]) 不一致")
    }
}

/// 左右分屏的文字盒一样大、只是左右对调。位图缓存的键要是只记盒子的大小不记位置，
/// 第二次渲染就会拿回第一次的位图，文字留在原来那一栏、压在画面上。
@Test func flippingTheSplitSideMovesTheTextEvenThoughTheBoxKeepsItsSize() throws {
    let size = CGSize(width: 1920, height: 1080)
    // 必须是同一个渲染器：这条契约管的就是它自己的缓存。
    let renderer = TextRenderer()
    var segment = TextSegment(start: 0, duration: 3, text: "分屏文字")
    segment.size = 60; segment.shadow = false
    segment.layout = .splitLeft
    let left = try #require(renderer.textFrame(for: state(segment), canvas: size, lightBackground: false))
    segment.layout = .splitRight
    let right = try #require(renderer.textFrame(for: state(segment), canvas: size, lightBackground: false))
    #expect(left.midX < size.width / 2, "左分屏时文字应当在左栏，实际 \(left)")
    #expect(right.midX > size.width / 2, "右分屏时文字应当在右栏，实际 \(right)")
    #expect(abs(left.width - right.width) < 1 && abs(left.midY - right.midY) < 1)
}

@Test func anchorAndAlignmentPlaceTheTextWhereTheyPromise() throws {
    let size = CGSize(width: 1920, height: 1080)
    let renderer = TextRenderer()
    var segment = TextSegment(start: 0, duration: 3, text: "对齐")
    segment.size = 60; segment.shadow = false; segment.x = 0.25; segment.y = 0.3
    let box = TextRenderer.box(for: segment, canvas: size)
    // 左对齐：锚点是文字块的左边缘。
    segment.alignment = .leading
    let leading = try #require(renderer.textFrame(for: state(segment), canvas: size, lightBackground: false))
    #expect(abs(leading.minX - (box.minX + 0.25 * box.width)) < 1)
    // 居中：锚点是中线。
    segment.alignment = .center
    let centered = try #require(renderer.textFrame(for: state(segment), canvas: size, lightBackground: false))
    #expect(abs(centered.midX - (box.minX + 0.25 * box.width)) < 1)
    // 右对齐：锚点是右边缘。
    segment.alignment = .trailing
    let trailing = try #require(renderer.textFrame(for: state(segment), canvas: size, lightBackground: false))
    #expect(abs(trailing.maxX - (box.minX + 0.25 * box.width)) < 1)
    // y 恒为整块文字的垂直中心（画布是左下原点，锚点从上往下量）。
    #expect(abs(centered.midY - (box.maxY - 0.3 * box.height)) < 1)
}

@Test func animationMovesAndFadesWithoutRelayingOutTheText() throws {
    let size = CGSize(width: 960, height: 540)
    let renderer = TextRenderer()
    var segment = TextSegment(start: 0, duration: 3, text: "上滑进场")
    segment.size = 48; segment.shadow = false; segment.color = .white
    let still = shot(renderer.image(for: state(segment), canvas: size, lightBackground: false), size: size)
    let stillBox = try #require(still.box)
    // 位移 0.06 画面高：包围盒整体上移，形状不变。
    let moved = shot(renderer.image(for: state(segment, offset: 0.06), canvas: size, lightBackground: false), size: size)
    let movedBox = try #require(moved.box)
    #expect(abs(movedBox.width - stillBox.width) <= 2 && abs(movedBox.height - stillBox.height) <= 2, "位移不该改变排版")
    // offset 为正表示向下；位图行序自上而下，所以 minY 变大。
    #expect(abs((movedBox.minY - stillBox.minY) - 0.06 * size.height) < 2, "位移量是 \(movedBox.minY - stillBox.minY)")
    // 半透明：覆盖面积不变，但没有一个像素是全不透明的。
    let faded = shot(renderer.image(for: state(segment, alpha: 0.4), canvas: size, lightBackground: false), size: size)
    #expect(faded.coverage > still.coverage / 2)
    #expect((0..<(size.width * size.height).intValue).allSatisfy { Int(faded.bytes[$0 * 4 + 3]) < 130 }, "淡入没有真的降低不透明度")
    // 放大：包围盒变大，中心不动。
    let bigger = try #require(shot(renderer.image(for: state(segment, scale: 1.5), canvas: size, lightBackground: false), size: size).box)
    #expect(bigger.width > stillBox.width * 1.3 && abs(bigger.midX - stillBox.midX) < 2)
}

@Test func typewriterRevealsCharactersWithoutReflowing() throws {
    let size = CGSize(width: 960, height: 540)
    let renderer = TextRenderer()
    var segment = TextPreset.typewriter.segment(start: 0, duration: 4)
    segment.text = "npm run build"; segment.alignment = .leading
    let full = shot(renderer.image(for: state(segment), canvas: size, lightBackground: false), size: size)
    let half = shot(renderer.image(for: state(segment, revealed: 6), canvas: size, lightBackground: false), size: size)
    let fullBox = try #require(full.box), halfBox = try #require(half.box)
    #expect(half.coverage < full.coverage / 2 + full.coverage / 8, "揭到一半却画了 \(half.coverage) / \(full.coverage) 的像素")
    #expect(half.coverage > 0)
    // 版面不动：已揭出的部分完全落在整段的包围盒里，左边缘对齐，右边缘随揭字变短。
    // 上下边不要求逐像素相同——"npm ru" 里没有 b、d 那样的高升部，墨迹本来就矮一点。
    #expect(abs(halfBox.minX - fullBox.minX) < 2, "揭字过程中左边缘动了")
    #expect(halfBox.minY >= fullBox.minY - 1 && halfBox.maxY <= fullBox.maxY + 1, "揭字过程中换行了")
    #expect(halfBox.maxX < fullBox.maxX - 4)
}

@Test func plateAndShadowStayBehindTheGlyphs() throws {
    let size = CGSize(width: 960, height: 540)
    let renderer = TextRenderer()
    var segment = TextPreset.lowerThird.segment(start: 0, duration: 3)
    segment.text = "字幕条"
    let withPlate = shot(renderer.image(for: state(segment), canvas: size, lightBackground: false), size: size)
    segment.plate = false
    let without = shot(renderer.image(for: state(segment), canvas: size, lightBackground: false), size: size)
    #expect(withPlate.coverage > without.coverage * 3, "底板没画出来")
    // 底板铺满整行时横贯整个文字盒。
    segment.plate = true; segment.plateFull = true
    let full = try #require(shot(renderer.image(for: state(segment), canvas: size, lightBackground: false), size: size).box)
    let box = TextRenderer.box(for: segment, canvas: size)
    #expect(abs(full.width - box.width) < 4, "铺满整行的底板宽 \(full.width)，文字盒宽 \(box.width)")
}

@Test func autoColorFollowsTheCanvasBackground() {
    var layout = CanvasLayout()
    layout.background = .graphite
    #expect(!SceneRenderer.isLightBackground(layout))
    #expect(TextRenderer.color(.auto, lightBackground: false).brightnessComponent > 0.9)
    #expect(TextRenderer.color(.auto, lightBackground: true).brightnessComponent < 0.2)
    // 自定义背景图亮度未知，按深色处理，白字加阴影在任何图上都读得出来。
    layout.backgroundImage = "Backgrounds/x.jpg"
    #expect(!SceneRenderer.isLightBackground(layout))
}

@Test func emptyOrInvisibleTextDrawsNothing() {
    let size = CGSize(width: 640, height: 360)
    let renderer = TextRenderer()
    var segment = TextSegment(start: 0, duration: 3, text: "")
    #expect(renderer.image(for: state(segment), canvas: size, lightBackground: false) == nil)
    segment.text = "看不见"
    #expect(renderer.image(for: state(segment, alpha: 0), canvas: size, lightBackground: false) == nil)
    segment.opacity = 0
    #expect(renderer.image(for: state(segment), canvas: size, lightBackground: false) == nil)
}

@Test func sceneRendererDrawsTextAboveEverythingAndIgnoresTheSceneZoom() throws {
    // 文字不跟着镜头推近放大：2 倍推近下它的包围盒必须和不推近时一模一样。
    let size = CGSize(width: 960, height: 540)
    let source = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    var edit = VideoEdit(duration: 4)
    edit.layout.padding = 0; edit.layout.cornerRadius = 0; edit.layout.shadow = false
    var segment = TextPreset.title.segment(start: 0, duration: 4)
    segment.text = "标题"; segment.color = .white; segment.shadow = false
    segment.enterKind = .none; segment.exitKind = .none; segment.enterDuration = 0; segment.exitDuration = 0
    edit.addText(segment)
    func whiteBox(_ image: CIImage) -> CGRect? {
        let width = Int(size.width), height = Int(size.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        CIContext().render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: textSpace)
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4] > 160 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: Double(minX), y: Double(minY), width: Double(maxX - minX + 1), height: Double(maxY - minY + 1))
    }
    let plain = try #require(whiteBox(SceneRenderer.frame(source: source, edit: edit, time: 2, size: size)))
    var zoomed = edit
    zoomed.focuses = [FocusSegment(start: 0, duration: 4, x: 0.2, y: 0.2, scale: 2)]
    let pushed = try #require(whiteBox(SceneRenderer.frame(source: source, edit: zoomed, time: 2, size: size)))
    #expect(abs(plain.midX - pushed.midX) < 2 && abs(plain.width - pushed.width) < 3,
            "推近后文字跑到了 \(pushed)，原本在 \(plain)")
}

/// 字幕：画在画面下方、逐词高亮只给那几个字换色、关掉烧录就一个像素都不画。
@Test func captionsBurnInAtTheBottomAndHighlightOnlyTheActiveWord() throws {
    let size = CGSize(width: 960, height: 540), bounds = CGRect(origin: .zero, size: size)
    let source = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    var edit = VideoEdit(duration: 6)
    edit.layout.padding = 0; edit.layout.cornerRadius = 0; edit.layout.shadow = false
    var style = CaptionStyle()
    style.lead = 0; style.tail = 0; style.minHold = 0; style.bridge = 0; style.fadeIn = 0.001; style.fadeOut = 0.001
    style.plate = false; style.highlight = .color; style.highlightColor = .amber; style.evenSplit = true
    edit.captionStyle = style
    edit.captionList = [CaptionCue(sourceStart: 1, sourceEnd: 5, text: "把留白调到四十")]

    func bitmap(_ image: CIImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
        CIContext().render(image, toBitmap: &bytes, rowBytes: Int(size.width) * 4, bounds: bounds, format: .RGBA8, colorSpace: textSpace)
        return bytes
    }
    let drawn = bitmap(SceneRenderer.frame(source: source, edit: edit, time: 3, size: size))
    // 底片是纯黑，字幕是画面上唯一亮的东西。
    var lit = 0, topHalf = 0
    for y in 0..<Int(size.height) {
        for x in 0..<Int(size.width) where drawn[(y * Int(size.width) + x) * 4] > 120 {
            lit += 1
            if y < Int(size.height) / 2 { topHalf += 1 }
        }
    }
    #expect(lit > 200, "字幕没有画出来（只有 \(lit) 个亮像素）")
    #expect(topHalf == 0, "字幕跑到画面上半部去了")

    // 逐词高亮：这一刻应当有一部分像素偏暖（琥珀），另一部分仍是白的。
    var amber = 0, white = 0
    for index in 0..<(Int(size.width * size.height)) {
        let red = Int(drawn[index * 4]), blue = Int(drawn[index * 4 + 2])
        if red > 150, blue < red - 40 { amber += 1 }
        if red > 150, blue > red - 20 { white += 1 }
    }
    #expect(amber > 20 && white > 20, "高亮词 \(amber) 像素、其余 \(white) 像素，逐词高亮没生效")

    // 关掉烧录：画面上一个字都不该有。
    // 只看红通道；alpha 恒为 255，连它一起扫会永远命中。
    func brightPixels(_ bytes: [UInt8]) -> Int {
        stride(from: 0, to: bytes.count, by: 4).reduce(0) { $0 + (bytes[$1] > 120 ? 1 : 0) }
    }
    var off = edit; off.captionStyle?.burnIn = false
    #expect(brightPixels(bitmap(SceneRenderer.frame(source: source, edit: off, time: 3, size: size))) == 0,
            "关掉烧录之后画面里还有字幕")

    // 没到时间也不画。
    #expect(brightPixels(bitmap(SceneRenderer.frame(source: source, edit: edit, time: 0.2, size: size))) == 0)
}

/// 药丸高亮：高亮词底下要有一块高亮色的实心圆角块，词本身要换成能压在它上面的反色。
@Test func pillHighlightPaintsAReadableBadgeBehindTheActiveWord() throws {
    let size = CGSize(width: 960, height: 540), bounds = CGRect(origin: .zero, size: size)
    let source = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    var edit = VideoEdit(duration: 6)
    edit.layout.padding = 0; edit.layout.cornerRadius = 0; edit.layout.shadow = false
    var style = CaptionStyle()
    style.lead = 0; style.tail = 0; style.minHold = 0; style.fadeIn = 0.001; style.fadeOut = 0.001
    style.plate = false; style.highlight = .pill; style.highlightColor = .amber; style.wordFade = 0.001
    edit.captionStyle = style
    edit.captionList = [CaptionCue(sourceStart: 1, sourceEnd: 5, text: "把留白调到四十")]

    var bytes = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
    CIContext().render(SceneRenderer.frame(source: source, edit: edit, time: 3, size: size),
                       toBitmap: &bytes, rowBytes: Int(size.width) * 4, bounds: bounds, format: .RGBA8, colorSpace: textSpace)
    // 琥珀色药丸：红高、蓝低，而且要成片而不是零星几个抗锯齿像素。
    var amber = 0, darkOnAmber = 0
    for index in 0..<Int(size.width * size.height) {
        let red = Int(bytes[index * 4]), green = Int(bytes[index * 4 + 1]), blue = Int(bytes[index * 4 + 2])
        if red > 180, green > 130, blue < 130 { amber += 1 }
        // 药丸里的字：整体暗，但邻近有琥珀，说明它压在药丸上而不是压在黑底上。
        if red < 80, green < 80, blue < 80, index % Int(size.width) > 0 {
            let left = index - 1
            if Int(bytes[left * 4]) > 180, Int(bytes[left * 4 + 2]) < 130 { darkOnAmber += 1 }
        }
    }
    #expect(amber > 300, "药丸没画出来（琥珀像素只有 \(amber) 个）")
    #expect(darkOnAmber > 0, "药丸上的字没有换成反色，读不出来")
}

private extension Double { var intValue: Int { Int(self) } }

/// 全屏卡段：画面层整体淡出并微微缩小，背景恒满幅留在原处。
/// 分屏：画面层缩到半区并挪到一侧，另一半留给文字。
@Test func stageTransformFadesOrSplitsThePictureButNeverTheBackground() throws {
    let size = CGSize(width: 960, height: 540), bounds = CGRect(origin: .zero, size: size)
    // 纯红画面 + 纯色背景，好分辨哪一块是画面、哪一块是背景。
    let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    func redPixels(_ image: CIImage) -> (count: Int, box: CGRect?) {
        var bytes = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
        CIContext().render(image, toBitmap: &bytes, rowBytes: Int(size.width) * 4, bounds: bounds, format: .RGBA8, colorSpace: textSpace)
        var count = 0, minX = Int(size.width), maxX = -1, minY = Int(size.height), maxY = -1
        for y in 0..<Int(size.height) {
            for x in 0..<Int(size.width) {
                let offset = (y * Int(size.width) + x) * 4
                guard bytes[offset] > 150, bytes[offset + 1] < 90, bytes[offset + 2] < 90 else { continue }
                count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let box = maxX >= minX ? CGRect(x: Double(minX), y: Double(minY), width: Double(maxX - minX + 1), height: Double(maxY - minY + 1)) : nil
        return (count, box)
    }

    var edit = VideoEdit(duration: 10)
    edit.layout.padding = 0; edit.layout.cornerRadius = 0; edit.layout.shadow = false
    edit.materializeLayers()
    let plain = redPixels(SceneRenderer.frame(source: source, edit: edit, time: 2, size: size))
    #expect(plain.count > Int(size.width * size.height) * 8 / 10, "常态下画面应当铺满画布，只有 \(plain.count) 个红像素")

    // 卡段正中：画面完全淡出，一个红像素都不该剩。
    let inserted = edit.insertHoldCard(at: 4, duration: 3, sourceDuration: 10, text: "第 2 章")
    let card = try #require(inserted)
    edit.updateText(id: card) { $0.layoutTransition = 0.4; $0.color = .white }
    let middle = redPixels(SceneRenderer.frame(source: source, edit: edit, time: 5.5, size: size))
    #expect(middle.count == 0, "卡段中间还剩 \(middle.count) 个红像素，画面没淡干净")
    // 过渡途中：画面还在，但已经缩小了。
    let entering = redPixels(SceneRenderer.frame(source: source, edit: edit, time: 4.12, size: size))
    let enteringBox = try #require(entering.box)
    #expect(entering.count > 0 && enteringBox.width < size.width - 2, "过渡中画面宽 \(enteringBox.width)，应当已经缩小")
    // 卡段之外完全不受影响。
    #expect(redPixels(SceneRenderer.frame(source: source, edit: edit, time: 2, size: size)).count == plain.count)

    // 分屏：画面缩到右半区。
    var split = VideoEdit(duration: 10)
    split.layout.padding = 0; split.layout.cornerRadius = 0; split.layout.shadow = false
    var text = TextSegment(start: 0, duration: 6, text: "左分屏")
    text.layout = .splitLeft; text.timelineStart = 0; text.layoutTransition = 0.001; text.color = .white
    split.addText(text)
    // 画面占多宽由「画面占比」决定，这里按当前版式算出来的目标去核对，不写死半区。
    let column = text.stageTarget
    let right = try #require(redPixels(SceneRenderer.frame(source: source, edit: split, time: 3, size: size)).box)
    #expect(abs(right.width / size.width - column.scale) < 0.02, "画面宽 \(right.width)，应当是 \(column.scale * size.width)")
    #expect(abs(right.midX / size.width - column.centerX) < 0.02, "画面中线在 \(right.midX / size.width)，应当是 \(column.centerX)")
    #expect(right.midX > size.width / 2, "左分屏时画面应当在右半边，中线在 \(right.midX)")
    split.updateText(id: text.id) { $0.layout = .splitRight }
    let left = try #require(redPixels(SceneRenderer.frame(source: source, edit: split, time: 3, size: size)).box)
    #expect(left.midX < size.width / 2, "右分屏时画面应当在左半边，中线在 \(left.midX)")
    #expect(abs(left.width - right.width) < 3)
}

/// 「全屏」以前只是换了个文字盒，画面纹丝不动，肉眼看和「叠加」一模一样。
/// 现在不管插不插入时长，全屏都让画面退场；「叠加」仍然只是盖在画面上。
@Test func fullscreenActuallyRetiresThePictureWhileOverlayLeavesItAlone() throws {
    let size = CGSize(width: 960, height: 540), bounds = CGRect(origin: .zero, size: size)
    let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    func redCount(_ image: CIImage) -> Int {
        var bytes = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
        CIContext().render(image, toBitmap: &bytes, rowBytes: Int(size.width) * 4, bounds: bounds, format: .RGBA8, colorSpace: textSpace)
        return (0..<Int(size.width * size.height)).reduce(0) {
            $0 + (bytes[$1 * 4] > 150 && bytes[$1 * 4 + 1] < 90 && bytes[$1 * 4 + 2] < 90 ? 1 : 0)
        }
    }
    var edit = VideoEdit(duration: 10)
    edit.layout.padding = 0; edit.layout.cornerRadius = 0; edit.layout.shadow = false
    edit.materializeLayers()
    var value = TextSegment(start: 0, duration: 6, text: "第 2 章")
    value.timelineStart = 1; value.layoutTransition = 0.3; value.color = .white
    value.layout = .overlay
    edit.addText(value)
    let overlaid = redCount(SceneRenderer.frame(source: source, edit: edit, time: 4, size: size))
    #expect(overlaid > Int(size.width * size.height) * 8 / 10, "叠加时画面应当照常铺满，只有 \(overlaid) 个红像素")

    edit.updateText(id: value.id) { $0.layout = .fullscreen }
    #expect(edit.text(id: value.id)?.holdClipID == nil, "这一段并没有插入时长，正是要测的那种")
    #expect(redCount(SceneRenderer.frame(source: source, edit: edit, time: 4, size: size)) == 0, "全屏时画面没有退场，和叠加没区别")
    // 过渡途中画面还在，只是已经在缩、在淡：半透明的红压在蓝背景上，按"偏红"计数。
    func reddish(_ image: CIImage) -> Int {
        var bytes = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
        CIContext().render(image, toBitmap: &bytes, rowBytes: Int(size.width) * 4, bounds: bounds, format: .RGBA8, colorSpace: textSpace)
        return (0..<Int(size.width * size.height)).reduce(0) { $0 + (Int(bytes[$1 * 4]) > Int(bytes[$1 * 4 + 2]) + 30 ? 1 : 0) }
    }
    let middle = reddish(SceneRenderer.frame(source: source, edit: edit, time: 1.15, size: size))
    #expect(middle > 0, "过渡中画面已经整个不见了，不是渐变")
    #expect(middle < reddish(SceneRenderer.frame(source: source, edit: edit, time: 0.5, size: size)), "过渡中画面没有在退")
    #expect(reddish(SceneRenderer.frame(source: source, edit: edit, time: 4, size: size)) == 0)
}

/// 分屏的「画面占比」要真的改变画面占的宽度，文字盒跟着补上另一栏。
@Test func theSplitRatioChangesHowMuchWidthThePictureGets() throws {
    let size = CGSize(width: 960, height: 540), bounds = CGRect(origin: .zero, size: size)
    let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    func redBox(_ image: CIImage) -> CGRect? {
        var bytes = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
        CIContext().render(image, toBitmap: &bytes, rowBytes: Int(size.width) * 4, bounds: bounds, format: .RGBA8, colorSpace: textSpace)
        var minX = Int(size.width), maxX = -1
        for y in 0..<Int(size.height) {
            for x in 0..<Int(size.width) {
                let offset = (y * Int(size.width) + x) * 4
                guard bytes[offset] > 150, bytes[offset + 1] < 90, bytes[offset + 2] < 90 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
            }
        }
        return maxX >= minX ? CGRect(x: Double(minX), y: 0, width: Double(maxX - minX + 1), height: 1) : nil
    }
    var edit = VideoEdit(duration: 10)
    edit.layout.padding = 0; edit.layout.cornerRadius = 0; edit.layout.shadow = false
    var value = TextSegment(start: 0, duration: 6, text: "右分屏")
    value.layout = .splitRight; value.timelineStart = 0; value.layoutTransition = 0.001; value.color = .white
    edit.addText(value)

    var widths: [Double] = []
    for ratio in [0.3, 0.5, 0.7] {
        edit.updateText(id: value.id) { $0.splitRatio = ratio }
        let box = try #require(redBox(SceneRenderer.frame(source: source, edit: edit, time: 3, size: size)))
        widths.append(box.width)
        // 画面始终留在左栏，右栏是文字的。
        #expect(box.maxX < size.width * 0.95, "画面右缘 \(box.maxX) 越过了文字栏")
    }
    #expect(widths[0] < widths[1] - 20 && widths[1] < widths[2] - 20, "占比没有改变画面宽度：\(widths)")
    // 七成占比时画面确实占了画布的大半。
    #expect(widths[2] > size.width * 0.55)
}

/// 分屏时浮在画面上的画中画不跟着缩到半栏里，而是按原大小待在画面那一栏。
@Test func theFloatingPortraitKeepsItsSizeAndStaysOnThePictureSide() throws {
    let size = CGSize(width: 960, height: 540), bounds = CGRect(origin: .zero, size: size)
    let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    let camera = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
    func greenBox(_ image: CIImage) -> CGRect? {
        var bytes = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
        CIContext().render(image, toBitmap: &bytes, rowBytes: Int(size.width) * 4, bounds: bounds, format: .RGBA8, colorSpace: textSpace)
        var minX = Int(size.width), maxX = -1, minY = Int(size.height), maxY = -1
        for y in 0..<Int(size.height) {
            for x in 0..<Int(size.width) {
                let offset = (y * Int(size.width) + x) * 4
                guard bytes[offset + 1] > 150, bytes[offset] < 90, bytes[offset + 2] < 90 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX >= minX ? CGRect(x: Double(minX), y: Double(minY), width: Double(maxX - minX + 1), height: Double(maxY - minY + 1)) : nil
    }
    var edit = VideoEdit(duration: 10)
    edit.layout.padding = 0; edit.layout.cornerRadius = 0; edit.layout.shadow = false
    var layout = CameraLayout()
    layout.enabled = true; layout.mode = .overlay; layout.shape = .roundedRectangle
    layout.cornerRadius = 0; layout.shadow = false; layout.size = 0.24; layout.x = 0.5; layout.y = 1
    edit.camera = layout
    let plain = try #require(greenBox(SceneRenderer.frame(source: source, edit: edit, time: 3, size: size, camera: camera)))

    var value = TextSegment(start: 0, duration: 6, text: "右分屏")
    value.layout = .splitRight; value.timelineStart = 0; value.layoutTransition = 0.001; value.color = .white
    edit.addText(value)
    let split = try #require(greenBox(SceneRenderer.frame(source: source, edit: edit, time: 3, size: size, camera: camera)))
    // 大小基本不变：跟着画面缩的话会小成 0.4 倍上下。
    // （只有人像会盖住画面栏六成以上时才收，等分分屏下收不到 5 %。）
    let scaled = plain.width * (edit.stage(at: 3).scale)
    #expect(split.width > plain.width * 0.95 && split.width < plain.width * 1.05,
            "人像从 \(plain.width) 变成了 \(split.width)")
    #expect(split.width > scaled * 1.5, "人像仍然是跟着画面一起缩的（\(split.width) 对 \(scaled)）")
    // 位置落在画面那一栏（右分屏 = 画面在左）。
    #expect(split.maxX < size.width * 0.55, "人像右缘在 \(split.maxX)，跑到文字栏里去了")

    // 整个版式过渡里画中画一帧都不能少：变换刚起步时它还约等于恒等，
    // 只看"是不是分屏"就摘、不看"变换是否已经生效"，会有那么一两帧两边都没画。
    edit.updateText(id: value.id) { $0.layoutTransition = 0.35 }
    for elapsed in stride(from: 0.0, through: 0.4, by: 0.005) {
        let frame = SceneRenderer.frame(source: source, edit: edit, time: elapsed, size: size, camera: camera)
        #expect(greenBox(frame) != nil, "过渡到第 \(elapsed) 秒时画中画整帧消失了")
    }
    edit.updateText(id: value.id) { $0.layoutTransition = 0.001 }

    // 人像是构图一部分的布局照旧跟着画面一起缩。
    edit.camera?.mode = .sideLeading
    let card = try #require(greenBox(SceneRenderer.frame(source: source, edit: edit, time: 3, size: size, camera: camera)))
    var noSplit = edit; noSplit.textList = []
    let cardPlain = try #require(greenBox(SceneRenderer.frame(source: source, edit: noSplit, time: 3, size: size, camera: camera)))
    #expect(card.width < cardPlain.width * 0.7, "侧边卡片没有跟着画面缩：\(card.width) 对 \(cardPlain.width)")
}

/// 「人像在后」布局下，摄像头轨有空档的那几帧（人像被删光、摄像头开得比录屏晚、卡段前后）
/// 背景不能整幅丢掉。缓存与 `frame` 对 behind 的判定必须完全一致：
/// 缓存按布局判定为"在后"就只缓存一层阴影，而 frame 因为这一帧没有人像走了普通分支，
/// 把那层透明阴影当成底图——背景就没了。
@Test func theBackdropCacheAndTheRendererAgreeOnWhetherThePortraitIsBehind() throws {
    let size = CGSize(width: 480, height: 270), bounds = CGRect(origin: .zero, size: size)
    let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 960, height: 540))
    var edit = VideoEdit(duration: 10)
    edit.layout.padding = 24
    var layout = CameraLayout(); layout.enabled = true; layout.mode = .behindTrailing
    edit.camera = layout

    let cache = SceneBackdropCache(), context = CIContext()
    func opaquePixels(camera: CIImage?) -> Int {
        let backdrop = cache.backdrop(edit: edit, sourceSize: CGSize(width: 960, height: 540), size: size,
                                      backgroundImage: nil, hasCamera: camera != nil, context: context)
        let frame = SceneRenderer.frame(source: source, edit: edit, time: 1, size: size, camera: camera, backdrop: backdrop)
        var bytes = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
        context.render(frame, toBitmap: &bytes, rowBytes: Int(size.width) * 4, bounds: bounds, format: .RGBA8, colorSpace: textSpace)
        return (0..<Int(size.width * size.height)).reduce(0) { $0 + (bytes[$1 * 4 + 3] > 200 ? 1 : 0) }
    }
    let total = Int(size.width * size.height)
    // 有人像的那几帧本来就是对的。
    let withCamera = opaquePixels(camera: CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480)))
    #expect(withCamera > total * 9 / 10, "有人像时画面就已经缺了一块：\(withCamera)/\(total)")
    // 摄像头轨空档的那几帧同样要铺满：背景是恒满幅的。
    let without = opaquePixels(camera: nil)
    #expect(without > total * 9 / 10, "摄像头轨空档处背景丢了 \(total - without) 个像素")
}

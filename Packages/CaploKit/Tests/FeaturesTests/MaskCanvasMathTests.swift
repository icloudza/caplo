import CoreGraphics
import CoreImage
import Foundation
import Testing
import EditingCore
import RenderKit
@testable import Features

/// 画布上的遮罩框必须和渲染出来的遮罩落在同一个位置。这里不只做来回换算的自洽检查，
/// 还真的渲染一帧、量出被遮住区域的外接矩形，和 `MaskCanvasMath` 算出的框对照——
/// 两者对不上意味着用户拖的框和实际盖住的地方不是一处，这个功能就是骗人的。
private let space = CGColorSpace(name: CGColorSpace.sRGB)!

private func roundTrip(_ point: CGPoint, videoRect: CGRect, edit: VideoEdit, sourceSize: CGSize, focus: FocusState) -> CGPoint? {
    guard let view = MaskCanvasMath.viewPoint(point, videoRect: videoRect, edit: edit, sourceSize: sourceSize, focus: focus) else { return nil }
    return MaskCanvasMath.normalized(view, videoRect: videoRect, edit: edit, sourceSize: sourceSize, focus: focus)
}

/// 渲染一帧，量出"没有被压暗"的那块区域的外接矩形（视图坐标，y 向上）。
private func brightBox(_ image: CIImage, size: CGSize) -> CGRect? {
    let width = Int(size.width), height = Int(size.height)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    CIContext().render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: space)
    var minX = width, maxX = -1, minRow = height, maxRow = -1
    for row in 0..<height {
        for x in 0..<width where bytes[(row * width + x) * 4] > 200 {
            minX = min(minX, x); maxX = max(maxX, x); minRow = min(minRow, row); maxRow = max(maxRow, row)
        }
    }
    guard maxX >= minX, maxRow >= minRow else { return nil }
    // 位图行序自上而下，换回 y 向上的视图坐标。
    return CGRect(x: Double(minX), y: Double(height - 1 - maxRow), width: Double(maxX - minX + 1), height: Double(maxRow - minRow + 1))
}

private func spotlightEdit(zoom: Double?, fixedFrame: Bool = false) -> VideoEdit {
    var edit = VideoEdit(duration: 4)
    edit.layout.padding = 40; edit.layout.cornerRadius = 0; edit.layout.shadow = false
    edit.layout.fixedFocusFrame = fixedFrame
    var spotlight = MaskSegment(start: 0, duration: 4, x: 0.36, y: 0.62, width: 0.28, height: 0.2, kind: .highlight)
    spotlight.darkness = 0.85; spotlight.fadeIn = 0; spotlight.fadeOut = 0
    edit.addMask(spotlight)
    if let zoom { edit.focuses = [FocusSegment(start: 0, duration: 4, x: 0.36, y: 0.62, scale: zoom)] }
    return edit
}

@Test(arguments: [nil, 1.8, 2.6] as [Double?])
func canvasFrameLandsWhereTheRendererActuallyMasks(zoom: Double?) throws {
    let size = CGSize(width: 960, height: 540)
    let source = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(origin: .zero, size: CGSize(width: 1920, height: 1080)))
    let edit = spotlightEdit(zoom: zoom)
    let mask = try #require(edit.maskList.first)
    let focus = SceneEvaluator.focus(edit: edit, time: 2)
    let predicted = try #require(MaskCanvasMath.viewRect(center: CGPoint(x: mask.x, y: mask.y),
                                                         size: CGSize(width: mask.width, height: mask.height),
                                                         videoRect: CGRect(origin: .zero, size: size),
                                                         edit: edit, sourceSize: CGSize(width: 1920, height: 1080), focus: focus))
    let rendered = try #require(brightBox(SceneRenderer.frame(source: source, edit: edit, time: 2, size: size), size: size))
    // 允许一个像素的取整误差；差得更多说明换算漏了某一级变换。
    #expect(abs(predicted.minX - rendered.minX) <= 1.5 && abs(predicted.maxX - rendered.maxX) <= 1.5,
            "横向预测 \(predicted) 实测 \(rendered)")
    #expect(abs(predicted.minY - rendered.minY) <= 1.5 && abs(predicted.maxY - rendered.maxY) <= 1.5,
            "纵向预测 \(predicted) 实测 \(rendered)")
}

@Test func canvasFrameFollowsTheFixedFocusFrameBranchToo() throws {
    // 固定取景：整幅画面不动，只有录屏框里的内容被推近，走的是另一支换算。
    let size = CGSize(width: 960, height: 540)
    let source = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(origin: .zero, size: CGSize(width: 1920, height: 1080)))
    let edit = spotlightEdit(zoom: 2.2, fixedFrame: true)
    let mask = try #require(edit.maskList.first)
    let focus = SceneEvaluator.focus(edit: edit, time: 2)
    let predicted = try #require(MaskCanvasMath.viewRect(center: CGPoint(x: mask.x, y: mask.y),
                                                         size: CGSize(width: mask.width, height: mask.height),
                                                         videoRect: CGRect(origin: .zero, size: size),
                                                         edit: edit, sourceSize: CGSize(width: 1920, height: 1080), focus: focus))
    let rendered = try #require(brightBox(SceneRenderer.frame(source: source, edit: edit, time: 2, size: size), size: size))
    #expect(abs(predicted.minX - rendered.minX) <= 1.5 && abs(predicted.maxY - rendered.maxY) <= 1.5,
            "预测 \(predicted) 实测 \(rendered)")
}

@Test func viewAndContentCoordinatesRoundTrip() throws {
    let videoRect = CGRect(x: 12, y: 7, width: 640, height: 360)
    let sourceSize = CGSize(width: 1920, height: 1080)
    for zoom in [nil, 1.6, 3.0] as [Double?] {
        let edit = spotlightEdit(zoom: zoom)
        let focus = SceneEvaluator.focus(edit: edit, time: 2)
        for point in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.94, y: 0.06)] {
            let back = try #require(roundTrip(point, videoRect: videoRect, edit: edit, sourceSize: sourceSize, focus: focus))
            #expect(abs(back.x - point.x) < 0.0005 && abs(back.y - point.y) < 0.0005, "倍率 \(String(describing: zoom)) 下 \(point) 变成了 \(back)")
        }
    }
}

@Test func degenerateGeometryReturnsNothingInsteadOfNaN() {
    let edit = spotlightEdit(zoom: nil)
    let focus = FocusState()
    #expect(MaskCanvasMath.normalized(.zero, videoRect: .zero, edit: edit, sourceSize: CGSize(width: 1920, height: 1080), focus: focus) == nil)
    #expect(MaskCanvasMath.viewPoint(.zero, videoRect: CGRect(x: 0, y: 0, width: 640, height: 360), edit: edit, sourceSize: .zero, focus: focus) == nil)
}

@Test func resizingHoldsTheOppositeEdgeAndStopsAtTheMinimumSide() {
    let rect = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)
    let widened = MaskCanvasMath.resize(rect, handle: .right, to: CGPoint(x: 0.9, y: 0.5))
    #expect(widened.minX == rect.minX && abs(widened.maxX - 0.9) < 0.0001 && widened.minY == rect.minY && widened.height == rect.height)
    let corner = MaskCanvasMath.resize(rect, handle: .topLeft, to: CGPoint(x: 0.1, y: 0.1))
    #expect(abs(corner.minX - 0.1) < 0.0001 && abs(corner.minY - 0.1) < 0.0001 && abs(corner.maxX - rect.maxX) < 0.0001 && abs(corner.maxY - rect.maxY) < 0.0001)
    // 拖过对边不翻面，停在最小边长上。
    let crossed = MaskCanvasMath.resize(rect, handle: .left, to: CGPoint(x: 0.95, y: 0.4), minimum: 0.01)
    #expect(crossed.width >= 0.0099 && crossed.maxX == rect.maxX)
    #expect(MaskCanvasMath.resize(rect, handle: .body, to: CGPoint(x: 0, y: 0)) == rect)
}

@Test func componentsClampTheCenterButLetTheBoxHangOffTheEdge() {
    // 中心被夹回画面内，但尺寸不夹：贴边的遮罩要能挂出画面外，否则边上会留一条没盖住的缝。
    let parts = MaskCanvasMath.components(CGRect(x: -0.3, y: -0.2, width: 0.5, height: 0.4))
    #expect(parts.x == 0 && parts.y == 0 && abs(parts.width - 0.5) < 0.0001 && abs(parts.height - 0.4) < 0.0001)
    let tiny = MaskCanvasMath.components(CGRect(x: 0.5, y: 0.5, width: 0, height: 0))
    #expect(tiny.width > 0 && tiny.height > 0)
}

/// 跟随镜头（手动加的那种）在 `model.edit` 里只有静态 x/y/scale，
/// 真正的运镜路径是构建播放项时 `resolvingTimelineFocus` 才编译出来的。
/// 画布上的编辑框必须用**渲染副本**求相机，否则聚焦一推近，框和画面就分家——
/// 用户看到的就是"高亮遮罩遇到聚焦冲突一下"。
@Test func canvasFrameMustUseTheResolvedFocusOrItDriftsFromThePicture() throws {
    let size = CGSize(width: 960, height: 540)
    let source = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    var edit = VideoEdit(duration: 0)
    edit.clips = [VideoClip(sourceStart: 0, duration: 10)]
    edit.layout.padding = 40; edit.layout.cornerRadius = 0; edit.layout.shadow = false
    edit.layout.fixedFocusFrame = false
    var spotlight = MaskSegment(start: 0, duration: 10, x: 0.36, y: 0.62, width: 0.28, height: 0.2, kind: .highlight)
    spotlight.darkness = 0.85; spotlight.fadeIn = 0; spotlight.fadeOut = 0
    edit.addMask(spotlight)
    // 手动加的跟随镜头：只有静态相机，路径要到解析时才有。
    var focus = FocusSegment(start: 0, duration: 4, x: 0.5, y: 0.5, scale: 1.9)
    focus.timelineStart = 2; focus.followsTimeline = true; focus.easeIn = 0.4; focus.easeOut = 0.4
    edit.focuses = [focus]
    let samples: [PointerSample] = (0..<200).map { step in
        let time = Double(step) / 20
        return PointerSample(time: time, x: min(0.95, 0.05 + time * 0.12), y: 0.5, kind: .move)
    }
    let resolved = edit.resolvingTimelineFocus(events: samples)
    #expect(resolved.focuses[0].path != nil, "渲染副本里应当已经编译出运镜路径")

    let time = 3.4
    let mask = try #require(edit.maskList.first)
    func box(using camera: VideoEdit) throws -> CGRect {
        try #require(MaskCanvasMath.viewRect(center: CGPoint(x: mask.x, y: mask.y),
                                             size: CGSize(width: mask.width, height: mask.height),
                                             videoRect: CGRect(origin: .zero, size: size),
                                             edit: edit, sourceSize: CGSize(width: 1920, height: 1080),
                                             focus: SceneEvaluator.focus(edit: camera, time: time)))
    }
    // 画面是用渲染副本渲染的。
    let rendered = try #require(brightBox(SceneRenderer.frame(source: source, edit: resolved, time: time, size: size), size: size))
    let correct = try box(using: resolved)
    let wrong = try box(using: edit)
    #expect(abs(correct.minX - rendered.minX) <= 2 && abs(correct.minY - rendered.minY) <= 2,
            "用渲染副本算出的框 \(correct) 与画面 \(rendered) 对不上")
    #expect(abs(wrong.minX - rendered.minX) > 6 || abs(wrong.minY - rendered.minY) > 6,
            "用未解析的数据算出的框 \(wrong) 竟然也对得上画面 \(rendered)，这条测试测不出东西")
}

/// 开了裁剪之后，画布上的框和真正被高亮的区域必须仍然重合。
///
/// 遮罩贴在**裁切之前**的完整画面上（换取景不会露出原文），所以它的坐标是整幅归一化；
/// 而成片矩形装的是裁切后的内容。少了这一级换算，框会整体偏移、而且比亮区窄 crop 倍——
/// 这一条在没有任何聚焦时就已经错了，推近之后误差还会被倍率放大。
@Test(arguments: [nil, 1.9] as [Double?])
func canvasFrameMatchesTheRendererWhenTheShotIsCropped(zoom: Double?) throws {
    let size = CGSize(width: 960, height: 540)
    let source = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    var edit = spotlightEdit(zoom: zoom)
    // 居中 1:1 裁切：横向只剩 0.5625。
    edit.layout.crop = CropRect(x: 0.21875, y: 0, width: 0.5625, height: 1)
    let mask = try #require(edit.maskList.first)
    let cropped = SceneRenderer.croppedSourceSize(CGSize(width: 1920, height: 1080), layout: edit.layout)
    let focus = SceneEvaluator.focus(edit: edit.cropResolved(), time: 2)
    let predicted = try #require(MaskCanvasMath.viewRect(center: CGPoint(x: mask.x, y: mask.y),
                                                         size: CGSize(width: mask.width, height: mask.height),
                                                         videoRect: CGRect(origin: .zero, size: size),
                                                         edit: edit, sourceSize: cropped, focus: focus))
    let rendered = try #require(brightBox(SceneRenderer.frame(source: source, edit: edit, time: 2, size: size), size: size))
    #expect(abs(predicted.minX - rendered.minX) <= 2 && abs(predicted.maxX - rendered.maxX) <= 2,
            "横向预测 \(predicted) 实测 \(rendered)")
    #expect(abs(predicted.width - rendered.width) <= 2,
            "框宽 \(predicted.width)，亮区宽 \(rendered.width)——差一个 crop 倍就是这一条")
    #expect(abs(predicted.minY - rendered.minY) <= 2 && abs(predicted.maxY - rendered.maxY) <= 2,
            "纵向预测 \(predicted) 实测 \(rendered)")

    // 来回换算要闭合，否则拖动会把裁切域的坐标存进整幅域的字段。
    for point in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.3, y: 0.7)] {
        let view = try #require(MaskCanvasMath.viewPoint(point, videoRect: CGRect(origin: .zero, size: size),
                                                         edit: edit, sourceSize: cropped, focus: focus))
        let back = try #require(MaskCanvasMath.normalized(view, videoRect: CGRect(origin: .zero, size: size),
                                                          edit: edit, sourceSize: cropped, focus: focus))
        #expect(abs(back.x - point.x) < 0.001 && abs(back.y - point.y) < 0.001, "\(point) 变成了 \(back)")
    }
}

/// 分屏 / 全屏卡段把画面层整体缩放挪位，编辑框也要跟着走。
@Test func canvasFrameFollowsTheStageTransform() throws {
    let size = CGSize(width: 960, height: 540)
    let source = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    var edit = spotlightEdit(zoom: nil)
    var text = TextSegment(start: 0, duration: 4, text: "左分屏")
    // 文字用暗色，免得它的白色笔画混进"亮区"的测量里。
    text.layout = .splitLeft; text.timelineStart = 0; text.layoutTransition = 0.001
    text.color = .ink; text.shadow = false
    edit.addText(text)
    let mask = try #require(edit.maskList.first)
    let stage = edit.stage(at: 2)
    #expect(!stage.isIdentity)
    let focus = SceneEvaluator.focus(edit: edit, time: 2)
    let predicted = try #require(MaskCanvasMath.viewRect(center: CGPoint(x: mask.x, y: mask.y),
                                                         size: CGSize(width: mask.width, height: mask.height),
                                                         videoRect: CGRect(origin: .zero, size: size),
                                                         edit: edit, sourceSize: CGSize(width: 1920, height: 1080),
                                                         focus: focus, stage: stage))
    let rendered = try #require(brightBox(SceneRenderer.frame(source: source, edit: edit, time: 2, size: size), size: size))
    #expect(abs(predicted.minX - rendered.minX) <= 2 && abs(predicted.maxX - rendered.maxX) <= 2,
            "分屏后横向预测 \(predicted) 实测 \(rendered)")
    #expect(abs(predicted.minY - rendered.minY) <= 2 && abs(predicted.maxY - rendered.maxY) <= 2,
            "分屏后纵向预测 \(predicted) 实测 \(rendered)")
    // 不带 stage 参数算出来的框会留在原处，说明这条测试测得到东西。
    let ignoring = try #require(MaskCanvasMath.viewRect(center: CGPoint(x: mask.x, y: mask.y),
                                                        size: CGSize(width: mask.width, height: mask.height),
                                                        videoRect: CGRect(origin: .zero, size: size),
                                                        edit: edit, sourceSize: CGSize(width: 1920, height: 1080), focus: focus))
    #expect(abs(ignoring.minX - rendered.minX) > 20)
}

/// 框在画面上很小的时候（分屏把画面压成一栏、或者遮罩本来就小），把手的命中区必须跟着收窄。
/// 不收的话八个把手连成一片，框体本身一点也点不着——表现为"选中之后只能改大小、挪不动"。
@Test func handleHitAreasShrinkWithTheBoxSoTheBodyStaysGrabbable() {
    let size: CGFloat = 9, slop: CGFloat = 5
    // 上下左右都有中点把手，一条边上三个锚点：半径必须小于边长四分之一才留得下可拖的缝。
    for side in stride(from: 12.0, through: 400.0, by: 2.0) {
        let rect = CGRect(x: 0, y: 0, width: side, height: side * 1.6)
        let reach = MaskCanvasMath.handleReach(rect, size: size, slop: slop)
        #expect(reach > 0)
        #expect(reach < min(rect.width, rect.height) / 4, "\(side) 点宽的框，命中半径 \(reach) 把框体挤没了")
        // 具体验一下：框体中心到左右两侧中点之间确实还有落点。
        let free = rect.width / 2 - reach
        #expect(free > 0.5, "\(side) 点宽的框没有可拖的空隙")
    }
    // 框够大时就是原来那个固定半径，手感不变。
    #expect(MaskCanvasMath.handleReach(CGRect(x: 0, y: 0, width: 300, height: 200), size: size, slop: slop) == size / 2 + slop)
    // 固定半径的老写法在小框上正是"挤没了"的那种：30 点宽的框，四分之一才 7.5 点。
    #expect(size / 2 + slop > 30.0 / 4, "夹具选的尺寸没能体现问题")
}

import CoreGraphics
import Testing
import EditingCore
import RenderKit
@testable import Features

/// 自定义布局的几何换算：坐标翻转往返、人像矩形 ↔ 归一化位置、录屏矩形 ↔ 偏移、把手 → 大小、卡片布局换算成等价叠放。
@Test func customLayoutMathRoundTrips() {
    let size = CGSize(width: 960, height: 540)
    let rect = CGRect(x: 100, y: 50, width: 200, height: 120)
    #expect(CustomLayoutMath.flip(CustomLayoutMath.flip(rect, in: size), in: size) == rect)
    #expect(CustomLayoutMath.canvasSize(fitting: CGSize(width: 800, height: 800), ratio: 16 / 9) == CGSize(width: 800, height: 450))
    var layout = CameraLayout(); layout.size = 0.3; layout.x = 0.25; layout.y = 0.75
    let placed = CustomLayoutMath.placingPortrait(at: CustomLayoutMath.flip(layout.rect(in: size), in: size), in: layout, size: size)
    #expect(abs(placed.x - 0.25) < 0.0001 && abs(placed.y - 0.75) < 0.0001)
    #expect(CustomLayoutMath.placingPortrait(at: CGRect(x: -500, y: -500, width: 10, height: 10), in: layout, size: size).x == 0)
    #expect(CustomLayoutMath.sizingPortrait(toWidth: 216, from: layout, size: size).size == 0.4)
    #expect(CustomLayoutMath.sizingPortrait(toWidth: 5, from: layout, size: size).size == 0.12)
    #expect(CustomLayoutMath.sizingPortrait(toWidth: 900, from: layout, size: size).size == 0.6)
    var canvas = CanvasLayout(); canvas.padding = 60
    let inner = CGRect(x: 60, y: 60, width: 840, height: 420)
    let centered = CustomLayoutMath.placingScreen(at: CGRect(x: inner.midX - 200, y: inner.midY - 100, width: 400, height: 200), in: canvas, size: size)
    #expect(abs(centered.screenOffsetX) < 0.0001 && abs(centered.screenOffsetY) < 0.0001)
    let corner = CustomLayoutMath.placingScreen(at: CGRect(x: inner.maxX - 400, y: inner.maxY - 200, width: 400, height: 200), in: canvas, size: size)
    #expect(abs(corner.screenOffsetX - 1) < 0.0001 && abs(corner.screenOffsetY - 1) < 0.0001)
    var edit = VideoEdit(duration: 5); edit.layout = canvas
    let scaled = CustomLayoutMath.scalingScreen(toWidth: 420, from: canvas, edit: edit, sourceSize: CGSize(width: 1600, height: 900), size: size)
    // 960 × 540、留白 60：内区 840 × 420，16 : 9 录屏受高度限制宽 746.7，拉到 420 即 0.5625。
    #expect(abs(scaled.screenScale - 420 / (420 * 16 / 9)) < 0.001)
    #expect(CustomLayoutMath.customEquivalent(camera: layout, edit: edit, sourceSize: CGSize(width: 16, height: 9)).camera == layout)
}

/// 卡片布局打开自定义布局时必须和画布上看到的一模一样：换算后的人像矩形与录屏矩形和原布局完全重合（1 像素内），
/// “在后”保留垫底层级、分屏不随聚焦缩小。
@Test func customEquivalentReproducesEveryCardLayout() {
    var edit = VideoEdit(duration: 5)
    edit.layout.padding = 40; edit.layout.shadow = true
    let source = CGSize(width: 1600, height: 900)
    let size = CGSize(width: 1920, height: 1080), padding = 40.0 * 1920 / 960
    for mode in [CameraLayout.Mode.sideLeading, .sideTrailing, .behindLeading, .behindTrailing, .splitLeading, .splitTrailing] {
        var card = CameraLayout(); card.mode = mode; card.sideHeight = mode == .behindLeading || mode == .behindTrailing ? 0.9 : 0.45; card.cornerRadius = 0.14
        let original = card.isSide ? card.sideFrames(canvas: size, padding: padding, screen: source)
            : card.isBehind ? card.behindFrames(canvas: size, padding: padding, screen: source)
            : card.splitFrames(canvas: size, padding: padding, screen: source)
        let converted = CustomLayoutMath.customEquivalent(camera: card, edit: edit, sourceSize: source)
        var custom = edit; custom.camera = converted.camera; custom.layout = converted.layout
        let portrait = SceneRenderer.cameraRect(edit: custom, layout: converted.camera, size: size, sourceSize: source)
        let screen = SceneRenderer.geometry(edit: custom, sourceSize: source, size: size).rect
        func close(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1 }
        #expect(close(portrait, original.camera), "\(mode) 人像 \(portrait) vs \(original.camera)")
        #expect(close(screen, original.screen), "\(mode) 录屏 \(screen) vs \(original.screen)")
        #expect(converted.camera.mode == .overlay && converted.camera.isValid)
        #expect(converted.camera.belowScreen == card.isBehind && converted.camera.underScreen == card.isBehind)
        if card.isSplit { #expect(!converted.camera.shrinkOnFocus && converted.camera.shadow) }
    }
}

/// 吸附：靠近画布边贴边并出竖线；靠近中线对齐并出十字；靠近另一块的边对齐；超出吸附距离不动；把手边吸附。
@Test func customLayoutSnapsToEdgesCentersAndNeighbours() {
    let canvas = CGRect(x: 0, y: 0, width: 960, height: 540), inner = CGRect(x: 60, y: 60, width: 840, height: 420)
    let nearLeft = CustomLayoutMath.snap(CGRect(x: 5, y: 200, width: 100, height: 60), canvas: canvas, inner: inner, targets: [])
    #expect(nearLeft.rect.minX == 0 && nearLeft.guides == [.vertical(0)])
    let nearInner = CustomLayoutMath.snap(CGRect(x: 66, y: 200, width: 100, height: 60), canvas: canvas, inner: inner, targets: [])
    #expect(nearInner.rect.minX == 60 && nearInner.guides == [.vertical(60)])
    let nearCentre = CustomLayoutMath.snap(CGRect(x: 434, y: 244, width: 100, height: 60), canvas: canvas, inner: inner, targets: [])
    #expect(nearCentre.rect.midX == 480 && nearCentre.rect.midY == 270 && nearCentre.guides == [.vertical(480), .horizontal(270)], "中线：十字")
    let neighbour = CGRect(x: 300, y: 100, width: 400, height: 225)
    let alignedRight = CustomLayoutMath.snap(CGRect(x: 705, y: 400, width: 100, height: 60), canvas: canvas, inner: inner, targets: [neighbour])
    #expect(alignedRight.rect.minX == 700 && alignedRight.guides == [.vertical(700)], "贴着另一块的右边")
    let far = CustomLayoutMath.snap(CGRect(x: 180, y: 200, width: 90, height: 60), canvas: canvas, inner: inner, targets: [neighbour])
    #expect(far.rect == CGRect(x: 180, y: 200, width: 90, height: 60) && far.guides.isEmpty)
    #expect(CustomLayoutMath.snapEdge(895, to: [900, 960]).value == 900 && CustomLayoutMath.snapEdge(895, to: [900, 960]).guide == 900)
    #expect(CustomLayoutMath.snapEdge(700, to: [900, 960]).guide == nil)
}

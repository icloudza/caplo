import Testing
import Foundation
@testable import EditingCore

@Test func cameraLayoutStaysInsideEveryCanvasAndValidatesPersistentValues() throws {
    var layout = CameraLayout()
    for shape in CameraLayout.Shape.allCases {
        layout.shape = shape
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 2160, height: 2160)] {
            for corner in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
                layout.x = corner.0; layout.y = corner.1; layout.size = 0.45
                let rect = layout.rect(in: size)
                #expect(CGRect(origin: .zero, size: size).contains(rect))
                #expect(abs(rect.width / min(size.width, size.height) - 0.45) < 0.001)
                if layout.y == 0 { #expect(rect.midY > size.height / 2) }
            }
        }
    }
    var edit = VideoEdit(duration: 5); edit.camera = layout
    try edit.validate(sourceDuration: 5)
    let restored = try JSONDecoder().decode(VideoEdit.self, from: JSONEncoder().encode(edit))
    #expect(restored == edit)
    var history = EditHistory(); history.record(edit)
    edit.camera?.mirrored.toggle()
    #expect(history.undo(current: edit) == restored)
    edit.camera?.size = .nan
    #expect(throws: EditError.self) { try edit.validate(sourceDuration: 5) }
}

/// 侧边：竖卡片（宽高 3 : 5，高 = 内容区高 × sideHeight）贴一侧、垂直居中，三分之二压在录屏边缘上；录屏在剩余区域等比适配；
/// 旧工程无 mode / sideHeight 字段按叠放、0.45 读；范围校验。
@Test func sideLayoutOverlapsTheScreenEdge() throws {
    var layout = CameraLayout()
    for canvas in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)] {
        for mode in [CameraLayout.Mode.sideLeading, .sideTrailing] {
            layout.mode = mode
            let frames = layout.sideFrames(canvas: canvas, padding: 40, screen: CGSize(width: 1600, height: 900))
            let inner = CGRect(x: 40, y: 40, width: canvas.width - 80, height: canvas.height - 80)
            #expect(inner.contains(frames.camera) && inner.contains(frames.screen))
            #expect(abs(frames.camera.height - inner.height * 0.45) < 0.001 && abs(frames.camera.width - frames.camera.height * 0.6) < 0.001)
            #expect(abs(frames.camera.midY - inner.midY) < 0.001)
            #expect(abs(frames.screen.width / frames.screen.height - 16 / 9) < 0.01)
            if mode == .sideLeading {
                #expect(frames.camera.minX == inner.minX)
                #expect(frames.screen.minX >= frames.camera.minX + frames.camera.width / 3 - 0.001, "录屏左缘不越过卡片三分之一处")
                #expect(frames.camera.maxX > frames.screen.minX, "卡片压在录屏上")
            } else {
                #expect(frames.camera.maxX == inner.maxX)
                #expect(frames.screen.maxX <= frames.camera.maxX - frames.camera.width / 3 + 0.001)
                #expect(frames.camera.minX < frames.screen.maxX)
            }
        }
    }
    #expect(layout.sideFrames(canvas: CGSize(width: 320, height: 180), padding: 0, screen: .zero).screen.isEmpty)
    // 侧边卡片随聚焦以中心为锚缩小。
    layout.mode = .sideLeading
    let base = layout.portraitRect(canvas: CGSize(width: 320, height: 180), padding: 0, progress: 0)
    let shrunk = layout.portraitRect(canvas: CGSize(width: 320, height: 180), padding: 0, progress: 1)
    #expect(abs(shrunk.midX - base.midX) < 0.001 && abs(shrunk.midY - base.midY) < 0.001 && abs(shrunk.width - base.width * 0.7) < 0.001)
    let legacy = Data(#"{"enabled":true,"shape":"circle","size":0.24,"x":1,"y":1,"mirrored":true,"shadow":true}"#.utf8)
    let decoded = try JSONDecoder().decode(CameraLayout.self, from: legacy)
    #expect(decoded.mode == .overlay && !decoded.isSide && decoded.sideHeight == 0.45)
    layout.mode = .sideLeading; layout.sideHeight = 0.7
    #expect(try JSONDecoder().decode(CameraLayout.self, from: JSONEncoder().encode(layout)) == layout)
    var invalid = CameraLayout(); invalid.sideHeight = 1.1
    #expect(!invalid.isValid)
}

/// 在后：大卡片（高 = 内容区高 × sideHeight）贴右、垂直居中；录屏向左靠、右缘压住卡片左侧四分之一；卡片不随聚焦缩小淡化。
@Test func behindLayoutTucksTheCardUnderTheScreen() throws {
    var layout = CameraLayout(); layout.mode = .behindTrailing; layout.sideHeight = 0.9
    #expect(layout.isBehind && layout.usesCard && !layout.isSide && layout.isValid)
    for canvas in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)] {
        let frames = layout.behindFrames(canvas: canvas, padding: 40, screen: CGSize(width: 1600, height: 900))
        let inner = CGRect(x: 40, y: 40, width: canvas.width - 80, height: canvas.height - 80)
        #expect(inner.contains(frames.camera) && inner.contains(frames.screen))
        #expect(abs(frames.camera.height - inner.height * 0.9) < 0.001 && abs(frames.camera.width - frames.camera.height * 0.6) < 0.001)
        #expect(frames.camera.maxX == inner.maxX && abs(frames.camera.midY - inner.midY) < 0.001)
        #expect(frames.screen.maxX <= frames.camera.minX + frames.camera.width / 4 + 0.001, "录屏右缘不越过卡片四分之一处")
        #expect(frames.screen.maxX > frames.camera.minX, "录屏压住卡片")
    }
    let canvas = CGSize(width: 320, height: 180)
    #expect(layout.portraitRect(canvas: canvas, padding: 0, progress: 1) == layout.portraitRect(canvas: canvas, padding: 0, progress: 0))
    #expect(layout.focusedOpacity(progress: 1) == 1)
    #expect(try JSONDecoder().decode(CameraLayout.self, from: JSONEncoder().encode(layout)) == layout)
}

/// 聚焦时缩小：以停靠点为锚（右下角仍贴右下角），推近到底缩到 focusedScale 倍、淡到 85 %；关掉就是原矩形；旧 JSON 按默认读；范围校验。
@Test func cameraShrinksTowardItsAnchorWhileFocused() throws {
    var layout = CameraLayout(); layout.size = 0.3
    let canvas = CGSize(width: 1920, height: 1080)
    let base = layout.rect(in: canvas), focused = layout.focusedRect(in: canvas, progress: 1), half = layout.focusedRect(in: canvas, progress: 0.5)
    #expect(layout.focusedRect(in: canvas, progress: 0) == base)
    #expect(abs(focused.width - base.width * 0.7) < 0.001 && abs(focused.height - base.height * 0.7) < 0.001)
    #expect(abs(focused.maxX - base.maxX) < 0.001 && abs(focused.minY - base.minY) < 0.001, "右下角人像缩小后仍贴右下角")
    #expect(abs(half.width - base.width * 0.85) < 0.001)
    layout.x = 0; layout.y = 0
    let topLeft = layout.rect(in: canvas), topLeftFocused = layout.focusedRect(in: canvas, progress: 1)
    #expect(abs(topLeftFocused.minX - topLeft.minX) < 0.001 && abs(topLeftFocused.maxY - topLeft.maxY) < 0.001)
    #expect(abs(layout.focusedOpacity(progress: 1) - 0.85) < 0.001 && layout.focusedOpacity(progress: 0) == 1)
    layout.shrinkOnFocus = false
    #expect(layout.focusedRect(in: canvas, progress: 1) == layout.rect(in: canvas) && layout.focusedOpacity(progress: 1) == 1)
    let legacy = Data(#"{"enabled":true,"shape":"circle","size":0.24,"x":1,"y":1,"mirrored":true,"shadow":true}"#.utf8)
    let decoded = try JSONDecoder().decode(CameraLayout.self, from: legacy)
    #expect(decoded.shrinkOnFocus && decoded.focusedScale == 0.7)
    var invalid = CameraLayout(); invalid.focusedScale = 0.2
    #expect(!invalid.isValid)
}

/// 聚焦包络：镜头中段为 1，镜头之外为 0；目标倍数为 1 的镜头不算推近。
@Test func focusStateCarriesTheEnvelope() {
    var edit = VideoEdit(duration: 10)
    edit.focuses = [FocusSegment(start: 2, duration: 4, x: 0.5, y: 0.5)]
    #expect(SceneEvaluator.focus(edit: edit, time: 4).envelope == 1)
    #expect(SceneEvaluator.focus(edit: edit, time: 1).envelope == 0)
    #expect(SceneEvaluator.focus(edit: edit, time: 8).envelope == 0)
    let rising = SceneEvaluator.focus(edit: edit, time: 2.1).envelope
    #expect(rising > 0 && rising < 1)
    edit.focuses = [FocusSegment(start: 2, duration: 4, x: 0.5, y: 0.5, scale: 1)]
    #expect(SceneEvaluator.focus(edit: edit, time: 4).envelope == 0)
}

/// 固定聚焦区域：新工程默认关；旧工程没有字段按开读（效果不变）；往返保留；聚焦状态带未钳制的目标点。
@Test func fixedFocusFrameDefaultsAndLegacy() throws {
    #expect(!CanvasLayout().fixedFocusFrame)
    let legacy = Data(#"{"ratio":"16:9","background":"鸢尾","padding":40,"cornerRadius":12,"shadow":true}"#.utf8)
    #expect(try JSONDecoder().decode(CanvasLayout.self, from: legacy).fixedFocusFrame)
    var layout = CanvasLayout(); layout.fixedFocusFrame = false
    #expect(try JSONDecoder().decode(CanvasLayout.self, from: JSONEncoder().encode(layout)).fixedFocusFrame == false)
    var edit = VideoEdit(duration: 10)
    edit.focuses = [FocusSegment(start: 2, duration: 4, x: 0.05, y: 0.9, scale: 2)]
    let state = SceneEvaluator.focus(edit: edit, time: 4)
    #expect(state.targetX == 0.05 && state.targetY == 0.9 && state.x > 0.05, "x 被钳制到半个视窗之内，目标点原样保留")
}

/// 分屏：卡片（3 : 5）在左、录屏在右并排同高、不重叠、留间距；整行缩到宽度刚好放下并居中；卡片不带聚焦效果；往返。
@Test func splitLayoutPutsTheCardBesideTheScreen() throws {
    var layout = CameraLayout(); layout.mode = .splitLeading
    #expect(layout.isSplit && layout.usesCard && layout.ignoresFocus && layout.isValid)
    for canvas in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)] {
        let frames = layout.splitFrames(canvas: canvas, padding: 40, screen: CGSize(width: 1600, height: 900))
        let inner = CGRect(x: 40, y: 40, width: canvas.width - 80, height: canvas.height - 80)
        #expect(inner.contains(frames.camera) && inner.contains(frames.screen))
        #expect(abs(frames.camera.height - frames.screen.height) < 0.001 && abs(frames.camera.width - frames.camera.height * 0.6) < 0.001)
        #expect(abs(frames.screen.width / frames.screen.height - 16 / 9) < 0.01)
        #expect(!frames.camera.intersects(frames.screen) && frames.screen.minX - frames.camera.maxX >= 40 - 0.001)
        #expect(abs((frames.camera.minX + frames.screen.maxX) / 2 - inner.midX) < 0.001 && abs(frames.camera.midY - inner.midY) < 0.001)
        #expect(frames.screen.maxX <= inner.maxX + 0.001)
    }
    let canvas = CGSize(width: 320, height: 180)
    #expect(layout.portraitRect(canvas: canvas, padding: 0, screen: canvas, progress: 1) == layout.portraitRect(canvas: canvas, padding: 0, screen: canvas, progress: 0))
    #expect(layout.portraitRect(canvas: canvas, padding: 0, screen: canvas, progress: 0) == layout.splitFrames(canvas: canvas, padding: 0, screen: canvas).camera)
    #expect(layout.focusedOpacity(progress: 1) == 1)
    #expect(layout.splitFrames(canvas: canvas, padding: 0, screen: .zero).screen.isEmpty)
    #expect(try JSONDecoder().decode(CameraLayout.self, from: JSONEncoder().encode(layout)) == layout)
}

/// 水平翻转是布局左右互换（不是镜像画面）：叠放的人像换到对侧，卡片布局换方向；两个方向的几何互为镜像。圆角进模型并校验。
@Test func layoutsFlipHorizontallyAndMirrorTheirGeometry() throws {
    var overlay = CameraLayout(); overlay.x = 1; overlay.y = 1
    #expect(overlay.flippedHorizontally().x == 0 && overlay.flippedHorizontally().y == 1 && overlay.flippedHorizontally().mode == .overlay)
    for mode in [CameraLayout.Mode.sideLeading, .behindLeading, .splitLeading] {
        var layout = CameraLayout(); layout.mode = mode
        let flipped = layout.flippedHorizontally()
        #expect(flipped.mode == mode.flipped && flipped.mode.flipped == mode && mode.leading && !flipped.mode.leading)
        let canvas = CGSize(width: 1920, height: 1080), screen = CGSize(width: 1600, height: 900)
        func frames(_ value: CameraLayout) -> (camera: CGRect, screen: CGRect) {
            value.isSide ? value.sideFrames(canvas: canvas, padding: 40, screen: screen)
                : value.isBehind ? value.behindFrames(canvas: canvas, padding: 40, screen: screen)
                : value.splitFrames(canvas: canvas, padding: 40, screen: screen)
        }
        let a = frames(layout), b = frames(flipped)
        #expect(abs(a.camera.minX - (canvas.width - b.camera.maxX)) < 0.001 && abs(a.screen.minX - (canvas.width - b.screen.maxX)) < 0.001, "\(mode)")
        #expect(a.camera.size == b.camera.size && a.screen.size == b.screen.size)
    }
    var rounded = CameraLayout(); rounded.cornerRadius = 0.3
    #expect(rounded.isValid && rounded.flippedHorizontally().cornerRadius == 0.3)
    rounded.cornerRadius = 0.6
    #expect(!rounded.isValid)
    // 新工程默认圆形 = 1 : 1 加 0.5；旧工程没有圆角字段时圆形照旧正圆、圆角矩形照旧 0.14。
    #expect(CameraLayout().cornerRadius == 0.5)
    let legacyCircle = Data(#"{"enabled":true,"shape":"circle","size":0.24,"x":1,"y":1,"mirrored":true,"shadow":true}"#.utf8)
    #expect(try JSONDecoder().decode(CameraLayout.self, from: legacyCircle).cornerRadius == 0.5)
    let legacyRounded = Data(#"{"enabled":true,"shape":"roundedRectangle","size":0.24,"x":1,"y":1,"mirrored":true,"shadow":true}"#.utf8)
    #expect(try JSONDecoder().decode(CameraLayout.self, from: legacyRounded).cornerRadius == 0.14)
}

/// 自定义布局的录屏位置 / 缩放进画面布局模型：旧工程缺省为原样（1、0、0），往返保留。
@Test func canvasLayoutKeepsScreenPlacement() throws {
    let legacy = Data(#"{"ratio":"16:9","background":"鸢尾","padding":40,"cornerRadius":12,"shadow":true}"#.utf8)
    let decoded = try JSONDecoder().decode(CanvasLayout.self, from: legacy)
    #expect(decoded.screenScale == 1 && decoded.screenOffsetX == 0 && decoded.screenOffsetY == 0)
    var layout = CanvasLayout(); layout.screenScale = 0.5; layout.screenOffsetX = 1; layout.screenOffsetY = -1
    #expect(try JSONDecoder().decode(CanvasLayout.self, from: JSONEncoder().encode(layout)) == layout)
}

/// 叠放的宽高比与垫底层级：3 : 5 的圆角矩形按宽高比出矩形；垫底的叠放不带聚焦效果；旧 JSON 缺省 4 : 3、不垫底；范围校验。
@Test func overlayAspectAndBelowScreen() throws {
    var layout = CameraLayout(); layout.shape = .roundedRectangle; layout.aspect = 0.6; layout.size = 0.3
    let rect = layout.rect(in: CGSize(width: 1920, height: 1080))
    #expect(abs(rect.width - 324) < 0.001 && abs(rect.height - 540) < 0.001)
    #expect(!layout.ignoresFocus && !layout.underScreen)
    layout.belowScreen = true
    #expect(layout.ignoresFocus && layout.underScreen && layout.focusedOpacity(progress: 1) == 1)
    layout.size = 0.6
    #expect(layout.isValid)
    layout.aspect = 0.1
    #expect(!layout.isValid)
    let legacy = Data(#"{"enabled":true,"shape":"roundedRectangle","size":0.24,"x":1,"y":1,"mirrored":true,"shadow":true}"#.utf8)
    let decoded = try JSONDecoder().decode(CameraLayout.self, from: legacy)
    #expect(abs(decoded.aspect - 4.0 / 3.0) < 0.0001 && !decoded.belowScreen)
    let rounded = decoded.rect(in: CGSize(width: 1920, height: 1080))
    #expect(abs(rounded.height - rounded.width * 0.75) < 0.001, "旧工程的圆角矩形仍是 4 : 3")
}

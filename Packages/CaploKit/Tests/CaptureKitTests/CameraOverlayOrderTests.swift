import CoreImage
import Testing
import EditingCore
@testable import RenderKit

/// 摄像头画中画始终叠在录制画面之上：时间线行序把摄像头排在画面之后（新默认）也一样，行序只描述布局。
@Test func cameraOverlayStaysAboveScreenRegardlessOfRowOrder() throws {
    var edit = VideoEdit(duration: 8)
    edit.prepareLayerEditing(camera: true, system: false, microphone: false)
    edit.layout.padding = 0; edit.layout.cornerRadius = 0; edit.layout.shadow = false
    var layout = CameraLayout(); layout.shape = .roundedRectangle; layout.shadow = false; layout.size = 0.4
    edit.camera = layout
    let screen = edit.clips[0].id, camera = try #require(edit.cameraClips?.first?.id)
    let size = CGSize(width: 320, height: 180), bounds = CGRect(origin: .zero, size: size)
    let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: bounds)
    let cameraImage = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: bounds)
    let context = CIContext()
    func counts(order: [UUID]) -> (green: Int, red: Int) {
        var value = edit; value.layerOrder = order
        let frame = SceneRenderer.frame(source: source, edit: value, time: 1, size: size, camera: cameraImage)
        var bytes = [UInt8](repeating: 0, count: 320 * 180 * 4)
        context.render(frame, toBitmap: &bytes, rowBytes: 320 * 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var green = 0, red = 0
        for o in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[o + 1] > 150 && bytes[o] < 80 { green += 1 } else if bytes[o] > 150 && bytes[o + 1] < 80 { red += 1 }
        }
        return (green, red)
    }
    let below = counts(order: [screen, camera]), above = counts(order: [camera, screen])
    #expect(below.green > 2000 && below.red > 30000, "摄像头行在画面之下时画中画仍在画面之上：\(below)")
    #expect(below == above, "行序不影响叠放次序")
}

/// 侧边合成：竖卡片贴左、压在录屏左缘上，录屏向右靠；卡片外的左上角是背景。
@Test func sideLayoutRendersTheCardOverTheScreenEdge() throws {
    var edit = VideoEdit(duration: 8)
    edit.prepareLayerEditing(camera: true, system: false, microphone: false)
    edit.layout.padding = 0; edit.layout.cornerRadius = 0; edit.layout.shadow = false
    var layout = CameraLayout(); layout.mode = .sideLeading; layout.shadow = false
    edit.camera = layout
    let size = CGSize(width: 320, height: 180), bounds = CGRect(origin: .zero, size: size)
    let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: bounds)
    let cameraImage = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: bounds)
    let frame = SceneRenderer.frame(source: source, edit: edit, time: 1, size: size, camera: cameraImage)
    var bytes = [UInt8](repeating: 0, count: 320 * 180 * 4)
    CIContext().render(frame, toBitmap: &bytes, rowBytes: 320 * 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8) { let o = (y * 320 + x) * 4; return (bytes[o], bytes[o + 1]) }
    // 卡片：高 81、宽 48.6，贴左、垂直居中（位图 y 向下，中心行 90）。
    #expect(pixel(10, 90).g > 150 && pixel(10, 90).r < 80, "卡片悬在外面的部分")
    #expect(pixel(40, 90).g > 150 && pixel(40, 90).r < 80, "卡片压在录屏上的部分")
    #expect(pixel(200, 90).r > 150 && pixel(200, 90).g < 80, "录屏")
    // 卡片外的左上角是画布背景（默认色板带绿），只要求它既不是人像的纯绿也不是录屏的纯红。
    let corner = pixel(5, 5)
    #expect(!(corner.g > 200 && corner.r < 40) && !(corner.r > 200 && corner.g < 40), "卡片外的左上角是背景")
    let geometry = SceneRenderer.geometry(edit: edit, sourceSize: size, size: size)
    #expect(abs(geometry.rect.minX - 16.2) < 0.01 && geometry.rect.maxX <= 320)
    #expect(SceneRenderer.cameraRect(edit: edit, layout: layout, size: size) == layout.sideFrames(canvas: size, padding: 0, screen: .zero).camera)
}

/// 镜头推近到底时人像面积缩到 49 %（0.7 × 0.7）且仍是绿色（淡到 85 % 仍压过红底）；关掉缩小则不变。
@Test func cameraShrinksWhileTheSceneIsFocused() throws {
    var edit = VideoEdit(duration: 8)
    edit.prepareLayerEditing(camera: true, system: false, microphone: false)
    edit.layout.padding = 0; edit.layout.cornerRadius = 0; edit.layout.shadow = false
    var layout = CameraLayout(); layout.shape = .roundedRectangle; layout.shadow = false; layout.size = 0.4
    edit.camera = layout
    edit.focuses = [FocusSegment(start: 0, duration: 8, x: 0.5, y: 0.5)]
    let size = CGSize(width: 320, height: 180), bounds = CGRect(origin: .zero, size: size)
    let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: bounds)
    let cameraImage = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: bounds)
    let context = CIContext()
    func green(_ value: VideoEdit, time: Double) -> Int {
        let frame = SceneRenderer.frame(source: source, edit: value, time: time, size: size, camera: cameraImage)
        var bytes = [UInt8](repeating: 0, count: 320 * 180 * 4)
        context.render(frame, toBitmap: &bytes, rowBytes: 320 * 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var count = 0
        // 淡到 85 % 的人像叠在红底上、按 sRGB 编码后红分量约 108：按“绿远高于红”判定，不按绝对阈值。
        for o in stride(from: 0, to: bytes.count, by: 4) where bytes[o + 1] > 150 && Int(bytes[o]) < Int(bytes[o + 1]) - 60 { count += 1 }
        return count
    }
    var still = edit; still.focuses = []
    let relaxed = green(still, time: 4), focused = green(edit, time: 4)
    #expect(relaxed > 2000)
    #expect(Double(focused) / Double(relaxed) > 0.43 && Double(focused) / Double(relaxed) < 0.55, "推近时人像面积约 49 %：\(focused)/\(relaxed)")
    var fixed = edit; fixed.camera?.shrinkOnFocus = false
    #expect(green(fixed, time: 4) == relaxed)
}


/// 整体推近：推到底后留白被推出画面，画布边缘也是录屏内容；固定聚焦区域时边缘仍是背景，框内内容放大。
/// 画布级变换：以聚焦点为中心放大并钳制，角落聚焦时不露出画布外。
@Test func wholeSceneZoomsUnlessTheFocusFrameIsFixed() throws {
    var edit = VideoEdit(duration: 8)
    edit.prepareLayerEditing(camera: false, system: false, microphone: false)
    edit.layout.padding = 60; edit.layout.cornerRadius = 0; edit.layout.shadow = false
    edit.focuses = [FocusSegment(start: 0, duration: 8, x: 0.5, y: 0.5, scale: 2)]
    let size = CGSize(width: 320, height: 180), bounds = CGRect(origin: .zero, size: size)
    let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: bounds)
    let context = CIContext()
    func red(_ value: VideoEdit, at x: Int, _ y: Int) -> Bool {
        let frame = SceneRenderer.frame(source: source, edit: value, time: 4, size: size)
        var bytes = [UInt8](repeating: 0, count: 320 * 180 * 4)
        context.render(frame, toBitmap: &bytes, rowBytes: 320 * 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let o = (y * 320 + x) * 4
        return bytes[o] > 200 && bytes[o + 1] < 60
    }
    var follow = edit; follow.layout.fixedFocusFrame = false
    var fixed = edit; fixed.layout.fixedFocusFrame = true
    #expect(red(follow, at: 4, 90) && red(follow, at: 160, 4), "整体推近 2 倍后画布边缘都是录屏")
    #expect(!red(fixed, at: 4, 90) && red(fixed, at: 160, 90), "固定聚焦区域时边缘仍是留白背景")
    var still = follow; still.focuses = []
    #expect(!red(still, at: 4, 90), "没有聚焦时留白照旧")
    let rect = CGRect(x: 20, y: 20, width: 280, height: 140)
    var state = FocusState(); state.scale = 2; state.targetX = 0; state.targetY = 0
    let corner = SceneRenderer.sceneZoom(focus: state, screen: rect, size: size)
    #expect(corner.tx == 0 && corner.ty == -180, "左上角聚焦：横向钳到 0，纵向钳到画布高的负值")
    state.targetX = 0.5; state.targetY = 0.5
    let centre = SceneRenderer.sceneZoom(focus: state, screen: rect, size: size)
    #expect(abs(centre.tx + 160) < 0.001 && abs(centre.ty + 90) < 0.001)
}

/// 在后合成：卡片贴右露出的部分是绿色，录屏压住卡片的地方是红色，录屏中央红色；推近时卡片不缩不淡；导出用的缓存层在这种布局下只有阴影。
@Test func behindLayoutKeepsTheCardUnderTheScreen() throws {
    var edit = VideoEdit(duration: 8)
    edit.prepareLayerEditing(camera: true, system: false, microphone: false)
    edit.layout.padding = 0; edit.layout.cornerRadius = 0; edit.layout.shadow = false; edit.layout.fixedFocusFrame = true
    var layout = CameraLayout(); layout.mode = .behindTrailing; layout.sideHeight = 0.9; layout.cornerRadius = 0.14
    edit.camera = layout
    let size = CGSize(width: 320, height: 180), bounds = CGRect(origin: .zero, size: size)
    let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: bounds)
    let cameraImage = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: bounds)
    let context = CIContext()
    func pixel(_ value: VideoEdit, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8) {
        let frame = SceneRenderer.frame(source: source, edit: value, time: 4, size: size, camera: cameraImage)
        var bytes = [UInt8](repeating: 0, count: 320 * 180 * 4)
        context.render(frame, toBitmap: &bytes, rowBytes: 320 * 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let o = (y * 320 + x) * 4; return (bytes[o], bytes[o + 1])
    }
    // 卡片：高 162、宽 97.2，x 222.8…320；录屏右缘在 247.1。
    #expect(pixel(edit, 300, 90).g > 150 && pixel(edit, 300, 90).r < 80, "卡片露出的部分")
    #expect(pixel(edit, 235, 90).r > 150 && pixel(edit, 235, 90).g < 80, "录屏压住卡片")
    #expect(pixel(edit, 100, 90).r > 150, "录屏")
    var focused = edit; focused.focuses = [FocusSegment(start: 0, duration: 8, x: 0.5, y: 0.5, scale: 2)]
    #expect(pixel(focused, 300, 90).g > 200 && pixel(focused, 300, 20).g > 200, "固定聚焦区域：推近时卡片不缩不淡")
    // 整体推近（1.2 倍、聚焦在左缘）：录屏与背景一起推近，卡片原地不动、露出的部分仍在原处。
    var whole = edit; whole.layout.fixedFocusFrame = false
    whole.focuses = [FocusSegment(start: 0, duration: 8, x: 0, y: 0.5, scale: 1.2)]
    #expect(pixel(whole, 310, 90).g > 200 && pixel(whole, 310, 20).g > 200, "整体推近时卡片不跟着推近")
    #expect(pixel(whole, 290, 90).r > 150 && pixel(whole, 290, 90).g < 80, "录屏推近后盖住更多卡片")
    let cache = SceneBackdropCache()
    let layer = cache.backdrop(edit: edit, sourceSize: size, size: size, backgroundImage: nil, context: context)
    var bytes = [UInt8](repeating: 0, count: 4)
    context.render(layer, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: 10, y: 10, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    #expect(bytes[3] == 0, "人像在后时缓存层是透明的阴影层，不是背景")
}

/// 分屏合成：左边卡片绿、右边录屏红、中间间距是背景；整体推近时录屏推近而卡片原地不动且仍在上面。
@Test func splitLayoutRendersCardBesideTheScreen() throws {
    var edit = VideoEdit(duration: 8)
    edit.prepareLayerEditing(camera: true, system: false, microphone: false)
    edit.layout.padding = 0; edit.layout.cornerRadius = 0; edit.layout.shadow = false; edit.layout.fixedFocusFrame = false
    var layout = CameraLayout(); layout.mode = .splitLeading; layout.shadow = false
    edit.camera = layout
    let size = CGSize(width: 320, height: 180), bounds = CGRect(origin: .zero, size: size)
    let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: bounds)
    let cameraImage = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: bounds)
    let context = CIContext()
    func pixel(_ value: VideoEdit, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8) {
        let frame = SceneRenderer.frame(source: source, edit: value, time: 4, size: size, camera: cameraImage)
        var bytes = [UInt8](repeating: 0, count: 320 * 180 * 4)
        context.render(frame, toBitmap: &bytes, rowBytes: 320 * 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let o = (y * 320 + x) * 4; return (bytes[o], bytes[o + 1])
    }
    // 间距 4：行高 132.9，卡片 x 0…79.7，录屏 x 83.7…320。
    #expect(pixel(edit, 40, 90).g > 150 && pixel(edit, 40, 90).r < 80, "卡片")
    #expect(pixel(edit, 200, 90).r > 150 && pixel(edit, 200, 90).g < 80, "录屏")
    let gap = pixel(edit, 81, 90)
    #expect(!(gap.g > 200 && gap.r < 40) && !(gap.r > 200 && gap.g < 40), "间距是背景")
    var whole = edit; whole.focuses = [FocusSegment(start: 0, duration: 8, x: 1, y: 0.5, scale: 1.2)]
    // 卡片纵向 23.5…156.5（位图行 23…156）：取行 40 与行 90 两个点。
    #expect(pixel(whole, 40, 90).g > 200 && pixel(whole, 40, 40).g > 200, "整体推近时卡片原地不动且仍在录屏之上")
    #expect(pixel(whole, 200, 90).r > 150)
    let geometry = SceneRenderer.geometry(edit: edit, sourceSize: size, size: size)
    #expect(abs(geometry.rect.minX - 83.7) < 0.2 && abs(geometry.rect.height - 132.9) < 0.2)
}

/// 自定义布局的录屏摆位：缩到一半并推到右下（Y 向下为正）后，录屏矩形贴着留白内区的右下角；卡片布局不受影响。
@Test func screenPlacementMovesTheScreenInsideThePadding() throws {
    var edit = VideoEdit(duration: 8)
    edit.layout.padding = 60
    let size = CGSize(width: 960, height: 540), padding = 60.0
    let full = SceneRenderer.geometry(edit: edit, sourceSize: CGSize(width: 1600, height: 900), size: size).rect
    edit.layout.screenScale = 0.5; edit.layout.screenOffsetX = 1; edit.layout.screenOffsetY = 1
    let rect = SceneRenderer.geometry(edit: edit, sourceSize: CGSize(width: 1600, height: 900), size: size).rect
    #expect(abs(rect.width - full.width / 2) < 0.001 && abs(rect.height - full.height / 2) < 0.001)
    #expect(abs(rect.maxX - (size.width - padding)) < 0.001 && abs(rect.minY - padding) < 0.001, "右下：Core Image 里 y 最小")
    edit.layout.screenOffsetX = -1; edit.layout.screenOffsetY = -1
    let topLeft = SceneRenderer.geometry(edit: edit, sourceSize: CGSize(width: 1600, height: 900), size: size).rect
    #expect(abs(topLeft.minX - padding) < 0.001 && abs(topLeft.maxY - (size.height - padding)) < 0.001)
    var card = CameraLayout(); card.mode = .splitLeading
    var split = edit; split.camera = card
    #expect(SceneRenderer.geometry(edit: split, sourceSize: CGSize(width: 1600, height: 900), size: size).rect == card.splitFrames(canvas: size, padding: padding, screen: CGSize(width: 1600, height: 900)).screen)
}

/// 背景 + 阴影缓存要随人像布局失效：从叠放换到分屏后录屏挪了位置，旧位置的阴影不能留在缓存里。
@Test func backdropCacheFollowsTheCameraLayout() throws {
    var edit = VideoEdit(duration: 8)
    edit.prepareLayerEditing(camera: true, system: false, microphone: false)
    edit.layout.padding = 60; edit.layout.cornerRadius = 0; edit.layout.shadow = true; edit.layout.shadowOpacity = 1
    edit.camera = CameraLayout()
    let size = CGSize(width: 960, height: 540), source = CGSize(width: 1600, height: 900)
    let cache = SceneBackdropCache(), context = CIContext()
    func darkness(_ value: VideoEdit, at x: Int, _ y: Int) -> Int {
        let image = cache.backdrop(edit: value, sourceSize: source, size: size, backgroundImage: nil, context: context)
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return Int(bytes[0]) + Int(bytes[1]) + Int(bytes[2])
    }
    let overlay = darkness(edit, at: 480, 52)
    var split = edit; split.camera?.mode = .splitLeading
    let afterSwitch = darkness(split, at: 480, 52)
    #expect(afterSwitch > overlay, "叠放时录屏底边在 y=60，阴影压在 (480, 52)；分屏后录屏抬高，那里应该亮回来")
    var back = split; back.camera?.mode = .overlay
    #expect(darkness(back, at: 480, 52) == overlay)
}

/// 人像全屏：人像铺满画布垫底，录屏小窗在右下；推近只放大小窗内容，人像不变；缓存层只有阴影。
@Test func cameraFullLayoutPutsTheScreenInAWindowOverThePortrait() throws {
    var edit = VideoEdit(duration: 8)
    edit.prepareLayerEditing(camera: true, system: false, microphone: false)
    edit.layout.padding = 0; edit.layout.cornerRadius = 0; edit.layout.shadow = false; edit.layout.fixedFocusFrame = false
    edit.layout.screenScale = 0.32; edit.layout.screenOffsetX = 1; edit.layout.screenOffsetY = 1
    var layout = CameraLayout(); layout.mode = .cameraFull
    edit.camera = layout
    let size = CGSize(width: 320, height: 180), bounds = CGRect(origin: .zero, size: size)
    let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: bounds)
    let cameraImage = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: bounds)
    let context = CIContext()
    func pixel(_ value: VideoEdit, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8) {
        let frame = SceneRenderer.frame(source: source, edit: value, time: 4, size: size, camera: cameraImage)
        var bytes = [UInt8](repeating: 0, count: 320 * 180 * 4)
        context.render(frame, toBitmap: &bytes, rowBytes: 320 * 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let o = (y * 320 + x) * 4; return (bytes[o], bytes[o + 1])
    }
    // 小窗：102.4 × 57.6，贴右下（位图 x 217.6…320，y 122.4…180）。
    #expect(pixel(edit, 10, 10).g > 200 && pixel(edit, 160, 90).g > 200, "人像铺满")
    #expect(pixel(edit, 300, 160).r > 200 && pixel(edit, 300, 160).g < 60, "右下小窗是录屏")
    #expect(SceneRenderer.cameraRect(edit: edit, layout: layout, size: size, sourceSize: size) == bounds)
    let window = SceneRenderer.geometry(edit: edit, sourceSize: size, size: size).rect
    #expect(abs(window.width - 102.4) < 0.01 && abs(window.maxX - 320) < 0.01 && abs(window.minY) < 0.01)
    var focused = edit; focused.focuses = [FocusSegment(start: 0, duration: 8, x: 0.5, y: 0.5, scale: 2)]
    #expect(pixel(focused, 10, 10).g > 200 && pixel(focused, 160, 90).g > 200, "推近时人像不动、不整幕推近")
    #expect(pixel(focused, 300, 160).r > 200)
    let layer = SceneBackdropCache().backdrop(edit: edit, sourceSize: size, size: size, backgroundImage: nil, context: context)
    var bytes = [UInt8](repeating: 0, count: 4)
    context.render(layer, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: 10, y: 100, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    #expect(bytes[3] == 0, "人像全屏时缓存层是透明的阴影层")
}

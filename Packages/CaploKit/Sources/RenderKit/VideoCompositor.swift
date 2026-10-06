@preconcurrency import AVFoundation
import CoreImage
import IOSurface
import CoreImage.CIFilterBuiltins
import EditingCore

/// 一个逻辑画面可跨多个编码格式；有效时间区间决定当前应读取哪条物理轨道。
public struct VideoTrackRange: Sendable {
    public let trackID: CMPersistentTrackID
    public let range: CMTimeRange
    public init(trackID: CMPersistentTrackID, range: CMTimeRange) { self.trackID = trackID; self.range = range }
}

/// 不可变指令同时用于实时播放器和导出会话；输出时间由统一求值器映射到素材时间。
public final class SceneInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let enablePostProcessing = false
    public let containsTweening = true
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    public let trackID: CMPersistentTrackID
    public let edit: VideoEdit
    public let cameraTrackID: CMPersistentTrackID?
    private let screenRoutes: [VideoTrackRange]
    private let cameraRoutes: [VideoTrackRange]
    public let pointers: PointerTimeline
    /// 自定义背景图；随指令一起交给合成器，避免每帧读盘。
    public let backgroundImage: CIImage?
    public let timeline: TimelineIndex
    /// 运镜规划只由这几样决定。拖遮罩 / 文字 / 字幕时它们一个都不变，
    /// 但每次鼠标移动都会换一次合成——不比一下就得把整条运镜路径重新规划一遍（大工程 6 毫秒以上）。
    public struct FocusPlan: Equatable, Sendable {
        /// 规划器只看这几样（见 TimelineFocusPlanner.init）：按层序排好的画面片段、镜头本身、镜头风格。
        /// 用 orderedScreenClips 而不是 clips + layerOrder：新加一条遮罩或文字会改 layerOrder，
        /// 但一点也不影响运镜，拿整份层序当键会白白触发重排。
        let clips: [VideoClip]
        let focuses: [FocusSegment]
        let style: AutoFocusStyle?
        let automatic: Bool
        public init(_ edit: VideoEdit) {
            clips = edit.orderedScreenClips; focuses = edit.focuses
            style = edit.focusStyle; automatic = edit.automaticFocus
        }
    }
    public let plan: FocusPlan
    /// 这一份是自己重新规划的（false 表示直接沿用了上一份的运镜路径）。测试用它确认复用真的发生了。
    public let replanned: Bool
    /// 设了裁切时换算到裁切区域的镜头（含整条运镜路径）。指令建立时算一次，逐帧直接用；
    /// 以前每一帧都把全部镜头连同十几万个关键帧重新换算一遍。没有裁切时为 nil。
    public let croppedFocuses: [FocusSegment]?
    public init(trackID: CMPersistentTrackID, edit: VideoEdit, cameraTrackID: CMPersistentTrackID? = nil, cameraRanges: [CMTimeRange] = [], screenRoutes: [VideoTrackRange] = [], cameraRoutes: [VideoTrackRange] = [], pointers: PointerTimeline = PointerTimeline(events: []), backgroundImage: CIImage? = nil, reusing previous: SceneInstruction? = nil) {
        self.trackID = trackID
        // 指令建立时一次规划；实时播放器与导出逐帧求值同一不可变路径。
        let plan = FocusPlan(edit)
        self.plan = plan
        if let previous, previous.plan == plan {
            var copy = edit; copy.focuses = previous.edit.focuses
            self.edit = copy; replanned = false
        } else {
            self.edit = edit.resolvingTimelineFocus(events: pointers.focusSamples); replanned = true
        }
        self.backgroundImage = backgroundImage
        if let crop = self.edit.layout.effectiveCrop, !crop.isFull { croppedFocuses = self.edit.cropResolved().focuses } else { croppedFocuses = nil }
        timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: edit.duration, preferredTimescale: 48_000))
        self.screenRoutes = (screenRoutes.isEmpty ? [VideoTrackRange(trackID: trackID, range: timeRange)] : screenRoutes).sorted { $0.range.start < $1.range.start }
        self.cameraRoutes = (cameraRoutes.isEmpty ? cameraRanges.compactMap { range in
            cameraTrackID.map { VideoTrackRange(trackID: $0, range: range) }
        } : cameraRoutes).sorted { $0.range.start < $1.range.start }
        self.cameraTrackID = self.cameraRoutes.first?.trackID
        self.pointers = pointers; timeline = TimelineIndex(clips: edit.orderedScreenClips)
        requiredSourceTrackIDs = Set((self.screenRoutes + self.cameraRoutes).map(\.trackID)).sorted().map { NSNumber(value: $0) }
    }
    public func pointerFrame(at time: Double) -> PointerFrame {
        // 片段级隐藏：该片段内不绘制箭头与点击。
        if let index = timeline.clipIndex(at: time), timeline.clips[index].cursorHidden { return PointerFrame() }
        return pointers.frame(at: time, timeline: timeline, effects: edit.pointer)
    }

    /// 空轨道区间可能产生黑色 sourceFrame，必须按有效区间判定；二分查询避免长工程逐段扫描。
    public func cameraVisible(at time: CMTime) -> Bool {
        cameraSource(at: time) != nil
    }
    public func screenSource(at time: CMTime) -> CMPersistentTrackID? { timeline.clipIndex(at: time.seconds) == nil ? nil : source(at: time, routes: screenRoutes) }
    public func cameraSource(at time: CMTime) -> CMPersistentTrackID? {
        edit.camera?.enabled == true ? source(at: time, routes: cameraRoutes) : nil
    }
    private func source(at time: CMTime, routes: [VideoTrackRange]) -> CMPersistentTrackID? {
        var lower = 0, upper = routes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if routes[middle].range.start <= time { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0, time < routes[lower - 1].range.end else { return nil }
        return routes[lower - 1].trackID
    }
}

/// 合成输出的色彩约定：BT.709（与导出文件、录制素材的标签一致）。
public enum SceneColor {
    /// 输出色彩空间：取"BT.709 三项标签"在 CoreMedia 里对应的那个空间（`kCGColorSpaceCoreMedia709`）。
    /// 解码端（播放器、缩略图、Core Image 读源帧）见到 709 标签用的就是它，渲染也必须用它，往返才是恒等的。
    /// 不能用 `CGColorSpace.itur_709`：那是按 709 摄像机曲线定义的另一条曲线，同样标 709，中灰实测被抬高约 15 个亮度级；
    /// 更早按 sRGB 曲线写也一样发灰（约 10 级）。导出画面应与原录制逐级一致，见 `exportKeepsTheRecordedBrightness`。
    public static let output: CGColorSpace = {
        let tags = [kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
                    kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
                    kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2] as CFDictionary
        return CVImageBufferCreateColorSpaceFromAttachments(tags)?.takeRetainedValue() ?? CGColorSpace(name: CGColorSpace.itur_709)!
    }()

    /// 在帧上标明 BT.709：像素缓冲的色彩附件给 Core Image / 编码器读，IOSurface 的色彩空间给 Core Animation 读——
    /// 预览把这一帧的 IOSurface 直接贴成图层内容，不标的话会被当成 sRGB 显示，编辑器里反而偏暗。
    public static func tag(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, output, .shouldPropagate)
        tagSurface(of: buffer)
    }

    /// 只补 IOSurface 的色彩空间（按缓冲附件推出来）。播放器输出的缓冲若是拷贝，附件会跟过来、IOSurface 属性不会，
    /// 显示前再补一次。
    public static func tagSurface(of buffer: CVPixelBuffer) {
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        let space = CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue()
            ?? CVImageBufferCreateColorSpaceFromAttachments(CVBufferCopyAttachments(buffer, .shouldPropagate) ?? [:] as CFDictionary)?.takeRetainedValue()
        guard let space, let list = space.copyPropertyList() else { return }
        IOSurfaceSetValue(surface, kIOSurfaceColorSpace, list)
    }
}

/// 串行渲染队列持有 Core Image 上下文；每次请求只有一帧，不缓存随时长增长的像素数据。
public final class VideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.caplo.video-compositor", qos: .userInitiated)
    private let cancellationLock = NSLock()
    private var generation = 0
    private let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    /// 背景与阴影只在布局变化时重画；只在渲染队列上访问。
    private let backdrops = SceneBackdropCache()
    public var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }
    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()]
    }
    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        cancellationLock.lock(); let requestedGeneration = generation; cancellationLock.unlock()
        queue.async { [self] in
            autoreleasepool {
                cancellationLock.lock(); let cancelled = requestedGeneration != generation; cancellationLock.unlock()
                if cancelled { request.finishCancelledRequest(); return }
                guard let instruction = request.videoCompositionInstruction as? SceneInstruction,
                      let output = request.renderContext.newPixelBuffer() else {
                    request.finish(with: NSError(domain: "Caplo.Render", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取合成画面。"])); return
                }
                let size = CGSize(width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output))
                let camera = instruction.cameraSource(at: request.compositionTime)
                    .flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
                let sourceImage = instruction.screenSource(at: request.compositionTime).flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
                let backdrop = backdrops.backdrop(edit: instruction.edit, sourceSize: SceneRenderer.croppedSourceSize(sourceImage?.extent.size ?? size, layout: instruction.edit.layout),
                                                  size: size, backgroundImage: instruction.backgroundImage,
                                                  hasCamera: camera != nil, context: context)
                let image = SceneRenderer.frame(source: sourceImage, edit: instruction.edit, time: request.compositionTime.seconds, size: size, camera: camera, pointer: instruction.pointerFrame(at: request.compositionTime.seconds), backgroundImage: instruction.backgroundImage, backdrop: backdrop, timeline: instruction.timeline, croppedFocuses: instruction.croppedFocuses)
                // 输出按 BT.709 编码并在帧上标明：导出文件的色彩标签是 BT.709，像素就必须按 BT.709 曲线写。
                // 以前按 sRGB 曲线写、却标成 BT.709，播放器按 BT.709 解读时暗部与中间调整体提亮约 10 个色阶，画面发灰。
                context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: SceneColor.output)
                SceneColor.tag(output)
                request.finish(withComposedVideoFrame: output)
            }
        }
    }
    public func cancelAllPendingVideoCompositionRequests() {
        // 标记尚未开始的请求，避免同步等待渲染队列导致回调重入死锁；已在绘制的一帧正常完成。
        cancellationLock.lock(); generation += 1; cancellationLock.unlock()
    }
}

/// 逐帧合成只做取样与混合：背景与阴影按（布局、尺寸、源尺寸）缓存成实际像素，布局不变就不重算。
/// 只在单一串行队列或 actor 内使用。
public final class SceneBackdropCache: @unchecked Sendable {
    private struct Key: Equatable {
        let layout: CanvasLayout
        /// 人像布局决定录屏矩形（侧边 / 在后 / 分屏都会挪动录屏），阴影随之变，必须进键；否则换布局后旧位置的阴影留在画面上。
        let camera: CameraLayout?
        let sourceSize: CGSize
        let size: CGSize
        /// 人像在后时缓存的是只有阴影的透明图层，逐帧再把人像垫进去。
        /// 这一帧有没有摄像头画面也算在里面：没有画面时 behind 分支不成立，缓存的必须是完整背景。
        let behind: Bool
    }
    private var key: Key?
    private var image: CIImage?

    public init() {}

    /// `hasCamera` 必须与这一帧真的有没有摄像头画面一致：`SceneRenderer.frame` 的 behind 分支
    /// 也带着这个条件。两边不一致时（布局是"人像在后"，可这一帧摄像头轨是空的）
    /// frame 会走普通分支拿这张图当底图，而缓存给的却是只有阴影的透明层——整幅背景就没了。
    public func backdrop(edit: VideoEdit, sourceSize: CGSize, size: CGSize, backgroundImage: CIImage?,
                         hasCamera: Bool = true, context: CIContext) -> CIImage {
        let behind = SceneRenderer.cameraIsBehind(edit) && hasCamera
        let key = Key(layout: edit.layout, camera: edit.camera, sourceSize: sourceSize, size: size, behind: behind)
        if key == self.key, let image { return image }
        let composed = behind
            ? (SceneRenderer.shadowLayer(edit: edit, sourceSize: sourceSize, size: size) ?? CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: CGRect(origin: .zero, size: size)))
            : SceneRenderer.backdrop(edit: edit, sourceSize: sourceSize, size: size, backgroundImage: backgroundImage)
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        guard size.width >= 1, size.height >= 1,
              CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { self.key = nil; self.image = nil; return composed }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        context.render(composed, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: space)
        let rendered = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: space])
        self.key = key; self.image = rendered
        return rendered
    }

    public func clear() { key = nil; image = nil }
}

/// 纯场景绘制：背景 → 阴影 → 裁切并聚焦的录屏 → 独立摄像头。预览和导出共享这个唯一像素实现。
public enum SceneRenderer {
    /// 成片中录屏所占矩形与圆角半径（输出像素坐标）。
    public struct Geometry: Equatable, Sendable {
        public let rect: CGRect
        public let radius: Double
    }

    public static func geometry(edit: VideoEdit, sourceSize: CGSize, size: CGSize) -> Geometry {
        let padding = edit.layout.padding * size.width / 960
        let rect: CGRect
        if let camera = edit.camera, camera.enabled, camera.isSide {
            // 侧边：录屏缩小并向右靠，给卡片悬在外面的那三分之一留位置。
            rect = camera.sideFrames(canvas: size, padding: padding, screen: sourceSize).screen
        } else if let camera = edit.camera, camera.enabled, camera.isBehind {
            // 在后：录屏向左靠，右缘压住卡片左侧四分之一。
            rect = camera.behindFrames(canvas: size, padding: padding, screen: sourceSize).screen
        } else if let camera = edit.camera, camera.enabled, camera.isSplit {
            // 分屏：录屏在右，与卡片同高并排。
            rect = camera.splitFrames(canvas: size, padding: padding, screen: sourceSize).screen
        } else {
            // 叠放：录屏按留白等比适配，再按自定义布局缩小并在剩余空间里摆位（Y 向下为正，换算成 Core Image 的向上坐标）。
            let fitted = LayoutGeometry.fittedSize(content: sourceSize, inside: size, padding: padding)
            let scale = min(1, max(0.3, edit.layout.screenScale.isFinite ? edit.layout.screenScale : 1))
            let width = fitted.width * scale, height = fitted.height * scale
            let inner = CGRect(x: padding, y: padding, width: max(0, size.width - 2 * padding), height: max(0, size.height - 2 * padding))
            let ox = min(1, max(-1, edit.layout.screenOffsetX.isFinite ? edit.layout.screenOffsetX : 0))
            let oy = min(1, max(-1, edit.layout.screenOffsetY.isFinite ? edit.layout.screenOffsetY : 0))
            rect = CGRect(x: inner.minX + max(0, inner.width - width) * (0.5 + ox / 2),
                          y: inner.minY + max(0, inner.height - height) * (0.5 - oy / 2), width: width, height: height)
        }
        let radius = min(edit.layout.cornerRadius * size.width / 960, min(rect.width, rect.height) / 2)
        return Geometry(rect: rect, radius: max(0, radius))
    }

    /// 成片中人像所占矩形（输出像素坐标）：叠放按归一化位置、侧边按卡片，都随聚焦包络 `focus` 缩小；分屏的卡片随录屏比例 `sourceSize` 排。
    public static func cameraRect(edit: VideoEdit, layout: CameraLayout, size: CGSize, sourceSize: CGSize = .zero,
                                  focus: Double = 0, region: CGRect? = nil) -> CGRect {
        layout.portraitRect(canvas: size, padding: edit.layout.padding * size.width / 960, screen: sourceSize, progress: focus, region: region)
    }

    /// 版式变换生效时用来算画面层几何的工程：留白按 `stage.paddingScale` 收起（分屏时收到 0，画面铺满自己那一栏）。
    /// 阴影、圆角、人像卡片都从这份工程取留白，才会跟画面一起贴到栏边。
    public static func stagedEdit(_ edit: VideoEdit, stage: StageTransform) -> VideoEdit {
        guard abs(stage.paddingScale - 1) > 0.0005 else { return edit }
        var result = edit
        result.layout.padding *= min(1, max(0, stage.paddingScale))
        return result
    }

    /// 按仿射变换缩放画面；缩小到一半以下时先用 Lanczos 缩好，再做剩下的平移（和镜像）。
    /// Core Image 的仿射变换按双线性取样，只看相邻四个像素：5K 全屏录制导出 1080p 要缩到三分之一，
    /// 文字会出锯齿、镜头平移时闪烁。Lanczos 先低通再取样。缩小不到一半时双线性已经够用，不多花这一步。
    public static func resampled(_ image: CIImage, by transform: CGAffineTransform) -> CIImage {
        let scale = hypot(transform.a, transform.b)
        guard transform.b == 0, transform.c == 0, abs(abs(transform.d) - scale) < 1e-9, scale > 0, scale < 0.5 else {
            return image.transformed(by: transform)
        }
        let reduced = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        // Lanczos 以原点为中心缩放：剩下的变换先抵掉这一层缩放，只留平移与镜像。
        return reduced.transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale).concatenating(transform))
    }

    /// 裁切后的源画面像素尺寸。
    public static func croppedSourceSize(_ full: CGSize, layout: CanvasLayout) -> CGSize {
        guard let crop = layout.effectiveCrop else { return full }
        return CGSize(width: full.width * crop.width, height: full.height * crop.height)
    }

    /// 背景加阴影，与时间无关。阴影参数以 960 点宽画布为参考等比缩放。
    public static func backdrop(edit: VideoEdit, sourceSize: CGSize, size: CGSize, backgroundImage: CIImage?) -> CIImage {
        let background = background(edit.layout, image: backgroundImage, size: size)
        guard let shadow = shadowLayer(edit: edit, sourceSize: sourceSize, size: size) else { return background }
        return shadow.composited(over: background)
    }

    /// 只有录屏阴影的透明图层（没有阴影返回 nil）；人像垫在录屏后面时，背景 → 人像 → 这层阴影 → 录屏。
    public static func shadowLayer(edit: VideoEdit, sourceSize: CGSize, size: CGSize) -> CIImage? {
        let bounds = CGRect(origin: .zero, size: size)
        let geometry = geometry(edit: edit, sourceSize: sourceSize, size: size)
        guard geometry.rect.width > 0, geometry.rect.height > 0, edit.layout.shadow, edit.layout.shadowOpacity > 0 else { return nil }
        let unit = size.width / 960
        let opacity = min(1, max(0, edit.layout.shadowOpacity))
        // 解析阴影：同一个距离场直接算出衰减，没有模糊 pass；柔和度取高斯 σ 的两倍，边缘处一半不透明度，与老路径观感一致。
        if let analytic = CardShape.shadow(rect: geometry.rect, radius: geometry.radius, blur: edit.layout.shadowBlur * unit * 2,
                                           offset: edit.layout.shadowOffset * unit, opacity: opacity, bounds: bounds) {
            return analytic
        }
        let shape = roundedShape(geometry, bounds: bounds)
        var shadow = shape.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
        ]).transformed(by: CGAffineTransform(translationX: 0, y: -edit.layout.shadowOffset * unit))
        if edit.layout.shadowBlur > 0 { shadow = shadow.applyingGaussianBlur(sigma: edit.layout.shadowBlur * unit) }
        return shadow.cropped(to: bounds)
    }

    /// 人像是否垫在录屏后面（在后 / 人像全屏，且人像打开）。
    static func cameraIsBehind(_ edit: VideoEdit) -> Bool { edit.camera?.enabled == true && edit.camera?.underScreen == true }

    static func roundedShape(_ geometry: Geometry, bounds: CGRect) -> CIImage {
        // 距离场覆盖率：4 次亚像素采样抗锯齿，形状指数可切超椭圆；内核不可用时回退系统圆角生成器。
        if let coverage = CardShape.coverage(rect: geometry.rect, radius: geometry.radius, bounds: bounds) { return coverage }
        let mask = CIFilter.roundedRectangleGenerator()
        mask.extent = geometry.rect; mask.radius = Float(geometry.radius)
        mask.color = CIColor.white
        return mask.outputImage!.cropped(to: bounds)
    }

    /// `backdrop`：缓存好的"背景 + 阴影"；人像在后时缓存的是只有阴影的透明图层（见 `SceneBackdropCache`）。
    /// `croppedFocuses`：调用方预先换算好的裁切后镜头（见 `SceneInstruction.croppedFocuses`）；不传就当场换算，结果相同。
    public static func frame(source full: CIImage?, edit: VideoEdit, time: Double, size: CGSize, camera: CIImage? = nil, pointer: PointerFrame = PointerFrame(), backgroundImage: CIImage? = nil, backdrop: CIImage? = nil, timeline: TimelineIndex? = nil, croppedFocuses: [FocusSegment]? = nil) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        let behind = cameraIsBehind(edit) && camera != nil
        // 文字投影与画面层的摆放各算一次：字幕、文字、版式变换共用同一份结果。
        let textSpans = edit.textList.isEmpty ? [] : edit.textSpans(in: max(0, time - 0.001)..<max(0.002, time + 0.001), using: timeline)
        let stage = edit.stage(at: time, spans: textSpans)
        let staged = !stage.isIdentity
        // 分屏时把浮在录屏之上的画中画摘出来单独摆：它不跟着画面缩到一栏里去。
        // 必须连着 `staged` 一起判断——版式刚起步的那一两帧变换还约等于恒等（staged 仍是 false），
        // 只看 split 的话画中画既没跟着画面画、也没被单独画，会整帧消失。
        let lifted = staged && stage.split && edit.camera?.isFloatingPortrait == true
        // 卡段正中画面层已经完全淡出。整条画面管线（解码、遮罩、圆角、光标、人像、两次重采样）
        // 再走一遍也只是乘上 0：直接画背景加文字。3 秒卡段里有 2.3 秒落在这一档。
        if stage.alpha < 0.002 {
            return withText(background(edit.layout, image: backgroundImage, size: size),
                            edit: edit, time: time, size: size, spans: textSpans)
        }
        // 没有录制块的区间只显示画布背景，独立摄像头仍可显示。
        guard let full else {
            let background = background(edit.layout, image: backgroundImage, size: size)
            // 没有录屏时分屏的卡片按画布比例当作录屏来排，位置不跳。
            guard let camera, let layout = edit.camera, layout.enabled else {
                return withText(background, edit: edit, time: time, size: size, spans: textSpans)
            }
            // 分屏时浮在上面的画中画同样摘出来单独摆，与有录屏时一致。
            if lifted {
                let picture = cameraOverlay(camera, edit: edit, layout: layout, over: background, size: size,
                                            sourceSize: size, region: stage.region(canvas: size))
                return withText(picture, edit: edit, time: time, size: size, spans: textSpans)
            }
            let base = staged ? CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: bounds) : background
            var picture = cameraOverlay(camera, edit: edit, layout: layout, over: base, size: size, sourceSize: size)
            if staged { picture = applyStage(stage, to: picture, size: size).composited(over: background).cropped(to: bounds) }
            return withText(picture, edit: edit, time: time, size: size, spans: textSpans)
        }
        // 遮罩贴在内容上，所以在裁切与聚焦变换之前就盖掉：推近时它跟着内容一起放大，
        // 裁切也只是从已经打过码的画面里取一块，不会因为换了取景就露出原文。
        let covered = masked(full, edit: edit, time: time, timeline: timeline)
        // 裁切保留原像素坐标系：指针仍按完整画面归一化坐标映射，聚焦则换算到裁切区域。
        var source = covered
        var edit = staged ? stagedEdit(edit, stage: stage) : edit
        if let crop = edit.layout.effectiveCrop {
            let extent = covered.extent
            let cropRect = CGRect(x: extent.minX + extent.width * crop.x, y: extent.minY + extent.height * (1 - crop.y - crop.height),
                                  width: extent.width * crop.width, height: extent.height * crop.height)
            source = covered.cropped(to: cropRect)
            // 聚焦坐标换到裁切区域。画布上的编辑框用同一个函数，两边的相机才是同一个点。
            // 版式变换只改留白不动镜头，所以指令里预先换算好的结果可以直接用。
            edit.focuses = croppedFocuses ?? edit.cropResolved().focuses
        }
        let geometry = geometry(edit: edit, sourceSize: source.extent.size, size: size)
        let rect = geometry.rect
        // 人像在后时 backdrop 是只有阴影的透明层，不能当底图，那条分支自己拼底图。
        // 版式变换生效时同理：画面层要单独画在透明底上，缩放淡出之后再叠到恒满幅的背景上。
        // 透明底图必须带尺寸：`CIImage.empty()` 的 extent 是空的，拿它做 alpha 混合结果不可预期。
        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: bounds)
        let base: CIImage
        if behind { base = CIImage.empty() }
        else if staged { base = shadowLayer(edit: edit, sourceSize: source.extent.size, size: size) ?? transparent }
        else { base = backdrop ?? self.backdrop(edit: edit, sourceSize: source.extent.size, size: size, backgroundImage: backgroundImage) }
        // 摄像头画中画始终叠在录制画面之上；时间线行序只描述布局（摄像头行默认在声音轨上方），不再决定叠放次序。
        guard rect.width > 0, rect.height > 0 else { return base }
        let focus = SceneEvaluator.focus(edit: edit, time: time, timeline: timeline)
        // 固定聚焦区域：只放大录屏框里的内容。否则整个画面（背景、留白、圆角框、光标效果）以聚焦点为中心一起推近，
        // 录屏先按 1 倍画好，再对整幅画面做画布级变换；人像画中画在这之后叠加，不跟随。
        // 人像全屏时聚焦只作用于小窗内容，整幕推近对它没有意义。
        let follow = !edit.layout.fixedFocusFrame && focus.scale > 1.0001 && edit.camera?.isCameraFull != true
        let contentScale = follow ? 1 : focus.scale
        let scale = rect.width / source.extent.width * contentScale
        let center = follow ? CGPoint(x: source.extent.midX, y: source.extent.midY)
            : CGPoint(x: source.extent.minX + source.extent.width * focus.x, y: source.extent.minY + source.extent.height * (1 - focus.y))
        let transform = CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
        var screen = resampled(source, by: transform).cropped(to: rect)
        if let effects = edit.pointer, effects.isValid {
            // 效果与内容共享变换，随后一并裁进屏幕圆角，不污染背景或覆盖摄像头。
            screen = PointerRenderer.overlay(frame: pointer, effects: effects, sourceBounds: full.extent, transform: transform,
                unit: size.width / 960 * contentScale, over: screen).cropped(to: rect)
        }
        let shape = roundedShape(geometry, bounds: bounds)
        let zoom = follow ? sceneZoom(focus: focus, screen: rect, size: size) : .identity
        if behind, let camera, let layout = edit.camera, layout.isValid {
            // 人像在后：背景（随整体推近）→ 卡片（固定，不带任何聚焦效果）→ 录屏阴影 + 录屏（随整体推近）。
            let background = background(edit.layout, image: backgroundImage, size: size)
            let under = staged ? CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: bounds)
                                : (follow ? background.transformed(by: zoom).cropped(to: bounds) : background)
            let card = cameraOverlay(camera, edit: edit, layout: layout, over: under, size: size, sourceSize: source.extent.size)
            let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: bounds)
            var upper = screen.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: shape]).cropped(to: bounds)
            // 缓存层在这种布局下就是只有阴影的透明层。
            if let shadow = backdrop ?? shadowLayer(edit: edit, sourceSize: source.extent.size, size: size) { upper = upper.composited(over: shadow) }
            if follow { upper = upper.transformed(by: zoom).cropped(to: bounds) }
            var picture = upper.composited(over: card).cropped(to: bounds)
            if staged { picture = applyStage(stage, to: picture, size: size).composited(over: background).cropped(to: bounds) }
            return withText(picture, edit: edit, time: time, size: size, spans: textSpans)
        }
        var composed = screen.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: shape]).cropped(to: bounds)
        if follow { composed = composed.transformed(by: zoom).cropped(to: bounds) }
        // 侧边 / 在后 / 分屏 / 人像全屏的人像是画面构图的一部分，照旧跟着画面一起变换（见上面的 lifted）。
        var picture = composed
        if let camera, let layout = edit.camera, layout.enabled, layout.isValid, !lifted {
            picture = cameraOverlay(camera, edit: edit, layout: layout, over: composed, size: size, sourceSize: source.extent.size, focus: focus.envelope)
        }
        if staged {
            picture = applyStage(stage, to: picture, size: size)
                .composited(over: background(edit.layout, image: backgroundImage, size: size)).cropped(to: bounds)
            if lifted, let camera, let layout = edit.camera, layout.enabled, layout.isValid {
                picture = cameraOverlay(camera, edit: edit, layout: layout, over: picture, size: size,
                                        sourceSize: source.extent.size, focus: focus.envelope, region: stage.region(canvas: size))
            }
        }
        return withText(picture, edit: edit, time: time, size: size, spans: textSpans)
    }

    /// 把画面层整体缩放挪位并淡出。背景不参与，所以这一步只作用在透明底上的画面层。
    static func applyStage(_ stage: StageTransform, to image: CIImage, size: CGSize) -> CIImage {
        var result = image.transformed(by: stage.affine(canvas: size)).cropped(to: CGRect(origin: .zero, size: size))
        let alpha = min(1, max(0, stage.alpha))
        if alpha < 0.999 {
            result = result.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            ])
        }
        return result
    }

    /// 字幕与文字层画在最上面，而且在输出画面坐标里：它们不跟着镜头推近一起放大，
    /// 否则标题会被推出画外。字幕在下、文字层在上。都没有时原样返回，一次滤镜都不建。
    static func withText(_ image: CIImage, edit: VideoEdit, time: Double, size: CGSize, spans: [TextSpan]) -> CIImage {
        guard time.isFinite, !edit.textList.isEmpty || !edit.captionList.isEmpty else { return image }
        var result = image
        let style = edit.captionStyleOrDefault
        // 只投影播放头附近这一段：一条 25 分钟的录音可能有四百句，逐帧全量投影会把播放拖垮。
        // 往前留够一句最长的显示时长，往后留一点好让"接上下一句"的规则算得出来。
        let window = max(0, time - 30)..<max(0.002, time + style.lead + style.bridge + 2)
        if !edit.captionList.isEmpty, style.burnIn,
           let caption = edit.activeCaption(at: time, spans: edit.captionSpans(in: window)) {
            // 药丸模式下药丸是高亮色，字要按药丸亮度取反色，不然就是同色压同色、一个字都读不出来。
            let pill = style.highlight == .pill
            let glyph = pill ? TextRenderer.Highlight.readableGlyphColor(on: style.highlightColor) : style.highlightColor
            let highlight = caption.highlightRange().map {
                TextRenderer.Highlight(location: $0.location, length: $0.length, color: glyph,
                                       pillColor: style.highlightColor, progress: caption.wordProgress, pill: pill)
            }
            if let layer = TextRenderer.shared.image(for: caption.renderState(style: style), canvas: size,
                                                     highlight: style.highlight == .none ? nil : highlight) {
                result = layer.composited(over: result)
            }
        }
        if !edit.textList.isEmpty {
            for state in edit.activeTexts(at: time, spans: spans) {
                guard let layer = TextRenderer.shared.image(for: state, canvas: size) else { continue }
                result = layer.composited(over: result)
            }
        }
        return result.cropped(to: CGRect(origin: .zero, size: size))
    }

    /// 画布背景是不是浅色；"自动"文字色据此在墨黑与白之间选。
    /// 当前帧生效的区域遮罩已经盖上的录制画面。没有遮罩时原样返回，一次滤镜都不建。
    /// 只查询播放头附近这一小段区间的投影，长工程也不必每帧扫描全部剪辑。
    static func masked(_ image: CIImage, edit: VideoEdit, time: Double, timeline: TimelineIndex?) -> CIImage {
        guard !edit.maskList.isEmpty, time.isFinite else { return image }
        let pad = MaskSegment.safetyPad + 0.001
        let spans = edit.maskSpans(in: max(0, time - pad)..<max(0.001, time + pad), using: timeline)
        return MaskRenderer.apply(edit.activeMasks(at: time, spans: spans), to: image)
    }

    /// `focus`：当前帧的推近包络 0…1，叠放的人像随它缩小并淡到 85 %（与画面推近同一条曲线）。
    /// 整体推近的画布级变换：以聚焦点在画布上的位置为中心放大 `focus.scale` 倍并移到画布中心，平移量钳制到不露出画布外。
    public static func sceneZoom(focus: FocusState, screen rect: CGRect, size: CGSize) -> CGAffineTransform {
        let s = max(1, focus.scale)
        let point = CGPoint(x: rect.minX + rect.width * min(1, max(0, focus.targetX)), y: rect.minY + rect.height * (1 - min(1, max(0, focus.targetY))))
        let tx = min(0, max(size.width - size.width * s, size.width / 2 - point.x * s))
        let ty = min(0, max(size.height - size.height * s, size.height / 2 - point.y * s))
        return CGAffineTransform(scaleX: s, y: s).concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    private static func cameraOverlay(_ source: CIImage, edit: VideoEdit, layout: CameraLayout, over background: CIImage, size: CGSize,
                                      sourceSize: CGSize, focus: Double = 0, region: CGRect? = nil) -> CIImage {
        let rect = cameraRect(edit: edit, layout: layout, size: size, sourceSize: sourceSize, focus: focus, region: region), bounds = CGRect(origin: .zero, size: size)
        let opacity = layout.focusedOpacity(progress: focus)
        guard source.extent.width > 0, source.extent.height > 0 else { return background }
        let scale = max(rect.width / source.extent.width, rect.height / source.extent.height)
        let transform = CGAffineTransform(translationX: -source.extent.midX, y: -source.extent.midY)
            .concatenating(CGAffineTransform(scaleX: layout.mirrored ? -scale : scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
        let image = resampled(source, by: transform).cropped(to: rect)
        // 一律按短边乘以面板里的圆角比例：圆形预设是 1 : 1 加 0.5，拉小就成圆角方块；人像全屏没有圆角。
        let radius = layout.isCameraFull ? 0 : min(rect.width, rect.height) * min(0.5, max(0, layout.cornerRadius))
        let shape: CIImage
        if let coverage = CardShape.coverage(rect: rect, radius: radius, bounds: bounds) { shape = coverage } else {
            let mask = CIFilter.roundedRectangleGenerator()
            mask.extent = rect; mask.color = .white; mask.radius = Float(radius)
            shape = mask.outputImage!.cropped(to: bounds)
        }
        var base = background
        // 垫在录屏下面的人像（在后、全屏）不画自己的阴影；分屏的卡片跟随画面布局的阴影设置。
        if layout.isSplit ? edit.layout.shadow : (layout.shadow && !layout.underScreen) {
            if let analytic = CardShape.shadow(rect: rect, radius: radius, blur: rect.width * 0.09, offset: rect.width * 0.025, opacity: 0.28 * opacity, bounds: bounds) {
                base = analytic.composited(over: base)
            } else {
                base = shape.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.28 * opacity)])
                    .transformed(by: CGAffineTransform(translationX: 0, y: -rect.width * 0.025))
                    .applyingGaussianBlur(sigma: rect.width * 0.045).composited(over: base)
            }
        }
        // 先按形状裁出人像，再整体（预乘的四个通道一起）按不透明度压暗，最后叠到底图上；阴影已按同一比例变淡。
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: bounds)
        var portrait = image.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: shape]).cropped(to: bounds)
        if opacity < 1 {
            portrait = portrait.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: opacity, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: opacity, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: opacity, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
            ])
        }
        return portrait.composited(over: base).cropped(to: bounds)
    }

    public static func palette(_ background: CanvasBackground) -> (CIColor, CIColor) {
        let colors = background.colors
        return (CIColor(red: colors.start.red, green: colors.start.green, blue: colors.start.blue),
                CIColor(red: colors.end.red, green: colors.end.green, blue: colors.end.blue))
    }

    /// 背景：自定义图片按填满裁切，否则按色板画对角渐变（纯色两端相同）。
    static func background(_ layout: CanvasLayout, image: CIImage?, size: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        if let image, image.extent.width > 0, image.extent.height > 0, image.extent.width.isFinite {
            let scale = max(size.width / image.extent.width, size.height / image.extent.height)
            let transform = CGAffineTransform(translationX: -image.extent.midX, y: -image.extent.midY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2))
            let filled = resampled(image, by: transform)
            let blur = max(0, min(100, layout.backgroundBlur)) * size.width / 960 * 0.5
            guard blur > 0.05 else { return filled.cropped(to: bounds) }
            // 先把边缘向外延伸再糊：不然四周会被透明像素拉淡，露出一圈灰边。
            return filled.clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: bounds)
        }
        let colors = palette(layout.background)
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: size.height); gradient.point1 = CGPoint(x: size.width, y: 0)
        gradient.color0 = colors.0; gradient.color1 = colors.1
        return gradient.outputImage!.cropped(to: bounds)
    }
}

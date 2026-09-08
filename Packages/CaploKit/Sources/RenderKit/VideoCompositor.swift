@preconcurrency import AVFoundation
import CoreImage
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
    public init(trackID: CMPersistentTrackID, edit: VideoEdit, cameraTrackID: CMPersistentTrackID? = nil, cameraRanges: [CMTimeRange] = [], screenRoutes: [VideoTrackRange] = [], cameraRoutes: [VideoTrackRange] = [], pointers: PointerTimeline = PointerTimeline(events: []), backgroundImage: CIImage? = nil) {
        self.trackID = trackID
        // 指令建立时一次规划；实时播放器与导出逐帧求值同一不可变路径。
        self.edit = edit.resolvingTimelineFocus(events: pointers.focusSamples)
        self.backgroundImage = backgroundImage
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
                                                  size: size, backgroundImage: instruction.backgroundImage, context: context)
                let image = SceneRenderer.frame(source: sourceImage, edit: instruction.edit, time: request.compositionTime.seconds, size: size, camera: camera, pointer: instruction.pointerFrame(at: request.compositionTime.seconds), backgroundImage: instruction.backgroundImage, backdrop: backdrop, timeline: instruction.timeline)
                context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
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
        let sourceSize: CGSize
        let size: CGSize
    }
    private var key: Key?
    private var image: CIImage?

    public init() {}

    public func backdrop(edit: VideoEdit, sourceSize: CGSize, size: CGSize, backgroundImage: CIImage?, context: CIContext) -> CIImage {
        let key = Key(layout: edit.layout, sourceSize: sourceSize, size: size)
        if key == self.key, let image { return image }
        let composed = SceneRenderer.backdrop(edit: edit, sourceSize: sourceSize, size: size, backgroundImage: backgroundImage)
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
        let fitted = LayoutGeometry.fittedSize(content: sourceSize, inside: size, padding: padding)
        let rect = CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
        let radius = min(edit.layout.cornerRadius * size.width / 960, min(rect.width, rect.height) / 2)
        return Geometry(rect: rect, radius: max(0, radius))
    }

    /// 裁切后的源画面像素尺寸。
    public static func croppedSourceSize(_ full: CGSize, layout: CanvasLayout) -> CGSize {
        guard let crop = layout.effectiveCrop else { return full }
        return CGSize(width: full.width * crop.width, height: full.height * crop.height)
    }

    /// 背景加阴影，与时间无关。阴影参数以 960 点宽画布为参考等比缩放。
    public static func backdrop(edit: VideoEdit, sourceSize: CGSize, size: CGSize, backgroundImage: CIImage?) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        let background = background(edit.layout, image: backgroundImage, size: size)
        let geometry = geometry(edit: edit, sourceSize: sourceSize, size: size)
        guard geometry.rect.width > 0, geometry.rect.height > 0, edit.layout.shadow, edit.layout.shadowOpacity > 0 else { return background }
        let unit = size.width / 960
        let shape = roundedShape(geometry, bounds: bounds)
        let opacity = min(1, max(0, edit.layout.shadowOpacity))
        var shadow = shape.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
        ]).transformed(by: CGAffineTransform(translationX: 0, y: -edit.layout.shadowOffset * unit))
        if edit.layout.shadowBlur > 0 { shadow = shadow.applyingGaussianBlur(sigma: edit.layout.shadowBlur * unit) }
        return shadow.cropped(to: bounds).composited(over: background)
    }

    static func roundedShape(_ geometry: Geometry, bounds: CGRect) -> CIImage {
        let mask = CIFilter.roundedRectangleGenerator()
        mask.extent = geometry.rect; mask.radius = Float(geometry.radius)
        mask.color = CIColor.white
        return mask.outputImage!.cropped(to: bounds)
    }

    public static func frame(source full: CIImage?, edit: VideoEdit, time: Double, size: CGSize, camera: CIImage? = nil, pointer: PointerFrame = PointerFrame(), backgroundImage: CIImage? = nil, backdrop: CIImage? = nil, timeline: TimelineIndex? = nil) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        // 没有录制块的区间只显示画布背景，独立摄像头仍可显示。
        guard let full else {
            let base = background(edit.layout, image: backgroundImage, size: size)
            if let camera, let layout = edit.camera, layout.enabled { return cameraOverlay(camera, layout: layout, over: base, size: size) }
            return base
        }
        // 裁切保留原像素坐标系：指针仍按完整画面归一化坐标映射，聚焦则换算到裁切区域。
        var source = full
        var edit = edit
        if let crop = edit.layout.effectiveCrop {
            let extent = full.extent
            let cropRect = CGRect(x: extent.minX + extent.width * crop.x, y: extent.minY + extent.height * (1 - crop.y - crop.height),
                                  width: extent.width * crop.width, height: extent.height * crop.height)
            source = full.cropped(to: cropRect)
            edit.focuses = edit.focuses.map { focus in
                var mapped = focus
                let point = crop.remap(CGPoint(x: focus.x, y: focus.y))
                mapped.x = min(1, max(0, point.x)); mapped.y = min(1, max(0, point.y))
                mapped.path = focus.path?.map { frame in
                    var moved = frame
                    let point = crop.remap(CGPoint(x: frame.x, y: frame.y))
                    moved.x = min(1, max(0, point.x)); moved.y = min(1, max(0, point.y))
                    return moved
                }
                return mapped
            }
        }
        let geometry = geometry(edit: edit, sourceSize: source.extent.size, size: size)
        let rect = geometry.rect
        let base = backdrop ?? self.backdrop(edit: edit, sourceSize: source.extent.size, size: size, backgroundImage: backgroundImage)
        // 摄像头画中画始终叠在录制画面之上；时间线行序只描述布局（摄像头行默认在声音轨上方），不再决定叠放次序。
        guard rect.width > 0, rect.height > 0 else { return base }
        let focus = SceneEvaluator.focus(edit: edit, time: time, timeline: timeline)
        let scale = rect.width / source.extent.width * focus.scale
        let center = CGPoint(x: source.extent.minX + source.extent.width * focus.x,
                             y: source.extent.minY + source.extent.height * (1 - focus.y))
        let transform = CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
        var screen = source.transformed(by: transform).cropped(to: rect)
        if let effects = edit.pointer, effects.isValid {
            // 效果与内容共享变换，随后一并裁进屏幕圆角，不污染背景或覆盖摄像头。
            screen = PointerRenderer.overlay(frame: pointer, effects: effects, sourceBounds: full.extent, transform: transform,
                unit: size.width / 960 * focus.scale, over: screen).cropped(to: rect)
        }
        let shape = roundedShape(geometry, bounds: bounds)
        let composed = screen.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: shape]).cropped(to: bounds)
        guard let camera, let layout = edit.camera, layout.enabled, layout.isValid else { return composed }
        return cameraOverlay(camera, layout: layout, over: composed, size: size)
    }

    private static func cameraOverlay(_ source: CIImage, layout: CameraLayout, over background: CIImage, size: CGSize) -> CIImage {
        let rect = layout.rect(in: size), bounds = CGRect(origin: .zero, size: size)
        guard source.extent.width > 0, source.extent.height > 0 else { return background }
        let scale = max(rect.width / source.extent.width, rect.height / source.extent.height)
        let transform = CGAffineTransform(translationX: -source.extent.midX, y: -source.extent.midY)
            .concatenating(CGAffineTransform(scaleX: layout.mirrored ? -scale : scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
        let image = source.transformed(by: transform).cropped(to: rect)
        let mask = CIFilter.roundedRectangleGenerator()
        mask.extent = rect; mask.color = .white
        mask.radius = Float(layout.shape == .circle ? rect.width / 2 : rect.height * 0.14)
        let shape = mask.outputImage!.cropped(to: bounds)
        var base = background
        if layout.shadow {
            base = shape.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.28)])
                .transformed(by: CGAffineTransform(translationX: 0, y: -rect.width * 0.025))
                .applyingGaussianBlur(sigma: rect.width * 0.045).composited(over: base)
        }
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: shape]).cropped(to: bounds)
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
            return image.transformed(by: transform).cropped(to: bounds)
        }
        let colors = palette(layout.background)
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: size.height); gradient.point1 = CGPoint(x: size.width, y: 0)
        gradient.color0 = colors.0; gradient.color1 = colors.1
        return gradient.outputImage!.cropped(to: bounds)
    }
}

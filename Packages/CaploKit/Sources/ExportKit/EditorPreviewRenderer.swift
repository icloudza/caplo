@preconcurrency import AVFoundation
import CoreImage
import ProjectKit
import RenderKit
import EditingCore

/// 每个编辑会话复用解码器和 GPU 上下文；在独立 actor 中合成，避免静帧渲染占用主线程。
/// 调用方按顺序提交请求，拖动期间只保留最新待处理画面，不并行启动解码。
public actor EditorPreviewRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private var generators: [(URL, AVAssetImageGenerator, CMTimeRange)] = []
    private var frames: [(URL, CMTime, CGImage)] = []
    private var rendering = false
    private var closed = false
    private var pointerProject: URL?
    private var pointers = PointerTimeline(events: [])
    private var timeline = TimelineIndex(clips: [])
    private var focusInput: VideoEdit?
    private var focusEdit: VideoEdit?
    private var background: (path: String, image: CIImage?)?
    private let backdrops = SceneBackdropCache()
    public private(set) var decodedFrameCount = 0
    public private(set) var generatorCount = 0

    public init() {}

    public func render(url: URL, document: ProjectDocument, edit: VideoEdit, time: Double) async throws -> CGImage {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard !rendering else { throw ProjectError.invalid(String(localized: "预览请求必须按顺序处理。")) }
        rendering = true
        defer { rendering = false }
        // 编辑会话持有工程租约，事件素材在会话内不变；只加载一次，剪辑变化才更新时间索引。
        if pointerProject != url {
            pointers = try ProjectMedia.pointerTimeline(url: url, document: document)
            pointerProject = url
            focusInput = nil; focusEdit = nil
        }
        // 静帧与播放器共用规划器；移动播放头只取样，范围 / 行序 / 跟随参数变化才重新规划。
        if focusInput != edit {
            focusInput = edit
            focusEdit = edit.resolvingTimelineFocus(events: pointers.focusSamples)
        }
        let renderedEdit = focusEdit ?? edit
        if timeline.clips != edit.orderedScreenClips { timeline = TimelineIndex(clips: edit.orderedScreenClips) }
        // 屏幕与摄像头独立映射，时间轴空白不是解码错误。
        let sourceImage = try await mediaImage(role: .screen, sourceTime: edit.sourceTime(at: time), url: url, document: document)
        let cameraTime = TimelineIndex(clips: edit.mediaClips(.camera)).sourceTime(at: time)
        let camera = edit.camera?.enabled == true ? try await mediaImage(role: .camera, sourceTime: cameraTime, url: url, document: document) : nil
            let ratio = edit.layout.aspect
            let size = CGSize(width: ratio >= 1 ? 1280 : 1280 * ratio, height: ratio >= 1 ? 1280 / ratio : 1280)
            if let path = edit.layout.backgroundImage {
                if background?.path != path { background = (path, ProjectMedia.backgroundImage(for: edit.layout, in: url)) }
            } else { background = nil }
            let clipHidesCursor = timeline.clipIndex(at: time).map { timeline.clips[$0].cursorHidden } ?? false
            // hasCamera 必须跟着这一帧的实情走：人像在后、但这一帧摄像头轨是空的时候，
            // 缓存里存的若是"只有阴影的透明层"，离线预览就会整幅背景消失。
            let backdrop = backdrops.backdrop(edit: edit, sourceSize: SceneRenderer.croppedSourceSize(sourceImage?.extent.size ?? size, layout: edit.layout),
                                              size: size, backgroundImage: background?.image, hasCamera: camera != nil, context: context)
            let result = SceneRenderer.frame(source: sourceImage, edit: renderedEdit, time: time, size: size, camera: camera,
                pointer: clipHidesCursor ? PointerFrame() : pointers.frame(at: time, timeline: timeline, effects: edit.pointer),
                backgroundImage: background?.image, backdrop: backdrop, timeline: timeline)
            // 在渲染 actor 内完成像素输出，避免 SwiftUI 显示时才执行延迟合成和访问解码资源。
            guard let rendered = context.createCGImage(result, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB), deferred: false) else {
                throw ProjectError.invalid(String(localized: "无法渲染预览。"))
            }
            try Task.checkCancellation()
            return rendered
    }

    private func mediaImage(role: MediaRole, sourceTime: Double?, url: URL, document: ProjectDocument) async throws -> CIImage? {
        guard let sourceTime else { return nil }
        var cursor = 0.0
        for segment in document.segments.sorted(by: { $0.id < $1.id }) {
            defer { cursor += segment.duration }
            guard sourceTime >= cursor, sourceTime < cursor + segment.duration else { continue }
            // 素材文件缺失（外置盘断开、文件损坏被删）时这一段当空白，见 ProjectStorage.load。
            guard let path = segment.files[role], ProjectStorage.mediaExists(path, in: url) else { return nil }
            let local = sourceTime - cursor - segment.offset(for: role)
            guard local >= 0 else { return nil }
            return try await image(url: ProjectStorage.mediaURL(path, in: url), at: CMTime(seconds: local, preferredTimescale: 48_000)).map { CIImage(cgImage: $0) }
        }
        return nil
    }

    /// 自定义布局对话框用的两张原帧（录屏、摄像头），不合成；缺失的返回空。
    public func stills(url: URL, document: ProjectDocument, edit: VideoEdit, time: Double) async throws -> (screen: CGImage?, camera: CGImage?) {
        guard !closed, !rendering else { throw ProjectError.invalid(String(localized: "预览请求必须按顺序处理。")) }
        rendering = true
        defer { rendering = false }
        let context = self.context
        let screen = try await mediaImage(role: .screen, sourceTime: edit.sourceTime(at: time), url: url, document: document)
        let cameraTime = TimelineIndex(clips: edit.mediaClips(.camera)).sourceTime(at: time)
        let camera = try await mediaImage(role: .camera, sourceTime: cameraTime, url: url, document: document)
        func cg(_ image: CIImage?) -> CGImage? { image.flatMap { context.createCGImage($0, from: $0.extent) } }
        return (cg(screen), cg(camera))
    }

    /// 屏幕和摄像头共用两项解码器、四项原帧缓存；缺失区间返回空值，真实解码错误继续上报。
    private func image(url: URL, at time: CMTime) async throws -> CGImage? {
        if let index = frames.firstIndex(where: { $0.0 == url && $0.1 == time }) {
            let cached = frames.remove(at: index); frames.append(cached); return cached.2
        }
        let generator: AVAssetImageGenerator, range: CMTimeRange
        if let index = generators.firstIndex(where: { $0.0 == url }) {
            let cached = generators.remove(at: index); generators.append(cached)
            generator = cached.1; range = cached.2
        } else {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProjectError.invalid(String(localized: "素材缺少视频轨道。")) }
            range = try await track.load(.timeRange)
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 1920, height: 1920)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            generators.append((url, generator, range)); generatorCount += 1
            if generators.count > 2 { generators.removeFirst().1.cancelAllCGImageGeneration() }
        }
        // 素材比工程记的时长短一点时（最后一帧的显示时长够不到末尾），末尾 1 秒内都取最后一帧；再远就是真的没画面。
        guard time >= range.start, time < range.end + CMTime(seconds: 1, preferredTimescale: 48_000) else { return nil }
        let clamped = time < range.end ? time : range.end - CMTime(value: 1, timescale: 600)
        if let index = frames.firstIndex(where: { $0.0 == url && $0.1 == clamped }) {
            let cached = frames.remove(at: index); frames.append(cached); return cached.2
        }
        let image = try await generator.image(at: clamped).image
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        decodedFrameCount += 1; frames.append((url, clamped, image))
        if frames.count > 4 { frames.removeFirst() }
        return image
    }

    /// 关闭会话才取消解码；普通拖动让当前请求完成，防止频繁取消导致一直没有可显示的画面。
    public func close() {
        closed = true
        generators.forEach { $0.1.cancelAllCGImageGeneration() }
        generators.removeAll(); frames.removeAll(); context.clearCaches(); backdrops.clear()
        pointerProject = nil; pointers = PointerTimeline(events: []); timeline = TimelineIndex(clips: []); background = nil
        focusInput = nil; focusEdit = nil
    }
}

@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import EditingCore
import ProjectKit
import RenderKit

/// 按需生成时间线胶片条缩略图：每个素材文件复用一个解码器，`tolerance` 为 0 时精确到帧，
/// 否则允许就近取关键帧以换取速度。调用串行，所有解码都在 actor 内完成。
public actor ThumbnailGenerator {
    private let url: URL
    private let document: ProjectDocument
    private let maximumSize: CGSize
    private var generators: [String: (generator: AVAssetImageGenerator, range: CMTimeRange)] = [:]
    private var closed = false
    /// 胶片条也要打码：时间线上一格一格的原始画面同样会把密钥摆在眼前。
    private var masks: [MaskSegment]
    private let context = CIContext(options: [.cacheIntermediates: false])

    public init(url: URL, document: ProjectDocument, maximumSize: CGSize = CGSize(width: 320, height: 200), masks: [MaskSegment] = []) {
        self.url = url; self.document = document; self.maximumSize = maximumSize; self.masks = masks
    }

    /// 遮罩变了要换一批缩略图；调用方负责清掉自己的缓存。
    public func setMasks(_ values: [MaskSegment]) { masks = values }

    /// 原素材时间对应的画面；超出素材范围返回 nil。
    public func image(at source: Double, tolerance: Double) async throws -> CGImage? {
        guard !closed, source.isFinite, source >= 0 else { return nil }
        var cursor = 0.0
        for segment in document.segments.sorted(by: { $0.id < $1.id }) {
            defer { cursor += segment.duration }
            guard source < cursor + segment.duration, let path = segment.files[.screen] else { continue }
            let entry = try await generator(for: path)
            let slack = CMTime(seconds: max(0, tolerance), preferredTimescale: 600)
            entry.generator.requestedTimeToleranceBefore = slack
            entry.generator.requestedTimeToleranceAfter = slack
            let local = min(max(0, source - cursor), max(0, entry.range.end.seconds - 0.001))
            try Task.checkCancellation()
            let frame = try await entry.generator.image(at: CMTime(seconds: local, preferredTimescale: 600)).image
            return masked(frame, atSource: source)
        }
        return nil
    }

    /// 缩略图取的是原素材的一帧，所以按源时间求遮罩，不经剪辑投影。
    /// 打码这一步失败就返回 nil：这一格空着也好过把没打码的原帧摆到时间线上。
    private func masked(_ frame: CGImage, atSource source: Double) -> CGImage? {
        guard !masks.isEmpty else { return frame }
        var edit = VideoEdit(duration: max(0.001, document.duration)); edit.maskList = masks
        let states = edit.sourceMasks(atSource: source)
        guard !states.isEmpty else { return frame }
        let image = CIImage(cgImage: frame)
        return context.createCGImage(MaskRenderer.apply(states, to: image), from: image.extent)
    }

    private func generator(for path: String) async throws -> (generator: AVAssetImageGenerator, range: CMTimeRange) {
        if let cached = generators[path] { return cached }
        let asset = AVURLAsset(url: try ProjectStorage.mediaURL(path, in: url))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProjectError.invalid("素材缺少视频轨道。") }
        let range = try await track.load(.timeRange)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = maximumSize
        generator.appliesPreferredTrackTransform = true
        generators[path] = (generator, range)
        return (generator, range)
    }

    public func close() {
        closed = true
        generators.values.forEach { $0.generator.cancelAllCGImageGeneration() }
        generators.removeAll()
    }
}

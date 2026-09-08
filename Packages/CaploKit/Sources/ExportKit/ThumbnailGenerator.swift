@preconcurrency import AVFoundation
import CoreGraphics
import ProjectKit

/// 按需生成时间线胶片条缩略图：每个素材文件复用一个解码器，`tolerance` 为 0 时精确到帧，
/// 否则允许就近取关键帧以换取速度。调用串行，所有解码都在 actor 内完成。
public actor ThumbnailGenerator {
    private let url: URL
    private let document: ProjectDocument
    private let maximumSize: CGSize
    private var generators: [String: (generator: AVAssetImageGenerator, range: CMTimeRange)] = [:]
    private var closed = false

    public init(url: URL, document: ProjectDocument, maximumSize: CGSize = CGSize(width: 320, height: 200)) {
        self.url = url; self.document = document; self.maximumSize = maximumSize
    }

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
            return try await entry.generator.image(at: CMTime(seconds: local, preferredTimescale: 600)).image
        }
        return nil
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

import AppKit
import ExportKit
import ProjectKit

/// 时间线胶片条的缩略图缓存：按原素材时间索引，片段起点要精确到帧，其余按 0.5 秒网格就近取帧。
/// 绘制时只查缓存并登记缺失项；后台串行生成，最近请求优先，来一张通知一次（视图自行合并重绘）。
/// 缓存有上限，久未使用的先淘汰；不随工程时长增长。
@MainActor
final class ThumbnailStore {
    struct Key: Hashable {
        let slot: Int
        let exact: Bool
    }
    static let grid = 0.5
    static let capacity = 512
    /// 只按张数封顶会踩坑：512 张 4K 缩略图能占一百多兆。张数与字节双上限，谁先到先淘汰谁。
    static let byteLimit = 24 * 1024 * 1024
    static let queueLimit = 96

    var onChange: (() -> Void)?
    /// 源画面宽高比，决定胶片条每格的宽度。
    let aspect: Double
    private let generator: ThumbnailGenerator
    private var images: [Key: CGImage] = [:]
    private var order: [Key] = []
    private var weights: [Key: Int] = [:]
    private var bytes = 0
    private var queue: [Key] = []
    private var inflight: Key?
    private var failed: Set<Key> = []
    private var worker: Task<Void, Never>?
    private var closed = false

    init(url: URL, document: ProjectDocument) {
        generator = ThumbnailGenerator(url: url, document: document)
        let size = document.capture?.pixelSize ?? .zero
        aspect = size.width > 0 && size.height > 0 ? Double(size.width / size.height) : 16.0 / 9
    }

    static func key(for time: Double, exact: Bool) -> Key {
        exact ? Key(slot: Int((time * 60).rounded()), exact: true) : Key(slot: Int((time / grid).rounded()), exact: false)
    }

    static func seconds(for key: Key) -> Double {
        key.exact ? Double(key.slot) / 60 : Double(key.slot) * grid
    }

    /// 命中即返回；未命中登记请求（最近的排在最前）并返回 nil。
    func image(at time: Double, exact: Bool) -> CGImage? {
        guard !closed, time.isFinite, time >= 0 else { return nil }
        let key = Self.key(for: time, exact: exact)
        if let image = images[key] {
            touch(key)
            return image
        }
        guard !failed.contains(key), inflight != key else { return nil }
        queue.removeAll { $0 == key }
        queue.append(key)
        if queue.count > Self.queueLimit { queue.removeFirst(queue.count - Self.queueLimit) }
        pump()
        return nil
    }

    var cachedCount: Int { images.count }

    private func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }

    private func store(_ image: CGImage, for key: Key) {
        if let previous = weights.removeValue(forKey: key) { bytes -= previous }
        images[key] = image
        let weight = max(1, image.bytesPerRow * image.height)
        weights[key] = weight; bytes += weight
        touch(key)
        while order.count > Self.capacity || (bytes > Self.byteLimit && order.count > 1) {
            guard let oldest = order.first else { break }
            order.removeFirst(); images[oldest] = nil
            bytes -= weights.removeValue(forKey: oldest) ?? 0
        }
    }

    private func pump() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil }
            while !Task.isCancelled, !self.closed, let key = self.queue.popLast() {
                self.inflight = key
                let image = try? await self.generator.image(at: Self.seconds(for: key), tolerance: key.exact ? 0 : Self.grid / 2)
                self.inflight = nil
                guard !self.closed else { return }
                if let image { self.store(image, for: key); self.onChange?() } else { self.failed.insert(key) }
            }
        }
    }

    func close() {
        closed = true
        worker?.cancel(); worker = nil
        queue.removeAll(); images.removeAll(); order.removeAll(); weights.removeAll(); bytes = 0
        let generator = self.generator
        Task { await generator.close() }
    }
}

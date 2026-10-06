import AppKit
import CoreImage
import EditingCore
import Observation

/// 光标样式格用的预览位图：按键缓存，进程内常驻；没有缓存时立刻返回空（格子先显示空底板），
/// 由一条串行后台队列逐张解码、扫边、渲染，完成后通过可观察属性刷新面板。素材本身也按需加载（见 `CursorAssets`）。
/// 早先每格开一个分离任务，十一个任务同时卡在同一把素材锁上等一秒多，把并发线程池占满，合成器也跟着卡。
@MainActor @Observable public final class CursorPreviews {
    public static let shared = CursorPreviews()
    private(set) var images: [String: NSImage] = [:]
    private var pending: Set<String> = []
    private let store: CursorAssets.Store
    /// 队列本身是低优先级（预热用），面板等着看的请求以 userInitiated 提交会临时抬高它。
    private nonisolated static let queue = DispatchQueue(label: "com.caplo.cursor-previews", qos: .utility)
    private nonisolated static let context = CIContext(options: [.cacheIntermediates: false])

    init(store: CursorAssets.Store = CursorAssets.store) { self.store = store }

    public func image(style: PointerEffects.Style, shape: PointerShape, height: CGFloat = 44) -> NSImage? {
        image(key: themeKey(style, shape, height), height: height) { [store] in CursorAssets.asset(style: style, shape: shape, in: store) }
    }
    /// 用户绘制样式的预览。
    public func image(customStyle id: String, height: CGFloat = 44) -> NSImage? {
        image(key: customKey(id, height), height: height) { [store] in Self.customAsset(id, store: store, height: height) }
    }
    /// 自绘样式的预览素材；"透明玻璃"是实时透镜，没有静态图可贴，画一枚放在几行文字条上的透镜。
    private nonisolated static func customAsset(_ id: String, store: CursorAssets.Store, height: CGFloat) -> CursorAssets.Asset? {
        if id == LiquidGlass.styleID, LiquidGlass.isAvailable {
            return CursorAssets.Asset(image: LiquidGlass.preview(size: height * 2), hotspot: CGPoint(x: 0.5, y: 0.5))
        }
        return CursorAssets.custom(id, in: store)
    }
    /// 预热：进入编辑器时在后台低优先级把一组样式（面板会先显示的那组）画好，切到光标面板时直接命中缓存；其他组等切到时再按需加载。
    public func warmUp(group: CursorStyle.Group, height: CGFloat = 44) {
        if group == .arrow {
            enqueue(key: themeKey(.tahoe, .arrow, height), height: height, qos: .utility) { [store] in CursorAssets.asset(style: .tahoe, shape: .arrow, in: store) }
        }
        for style in CursorStyle.styles(in: group) {
            enqueue(key: customKey(style.id, height), height: height, qos: .utility) { [store] in Self.customAsset(style.id, store: store, height: height) }
        }
    }

    private nonisolated func themeKey(_ style: PointerEffects.Style, _ shape: PointerShape, _ height: CGFloat) -> String { "\(style.rawValue)/\(shape.rawValue)/\(Int(height))" }
    private nonisolated func customKey(_ id: String, _ height: CGFloat) -> String { "custom/\(id)/\(Int(height))" }

    private func image(key: String, height: CGFloat, asset: @escaping @Sendable () -> CursorAssets.Asset?) -> NSImage? {
        if let image = images[key] { return image }
        enqueue(key: key, height: height, qos: .userInitiated, asset: asset)
        return nil
    }

    private func enqueue(key: String, height: CGFloat, qos: DispatchQoS, asset: @escaping @Sendable () -> CursorAssets.Asset?) {
        guard images[key] == nil, !pending.contains(key) else { return }
        pending.insert(key)
        Self.queue.async(qos: qos) {
            let rendered = Self.render(asset: asset(), height: height)
            Task { @MainActor in
                self.pending.remove(key)
                if let rendered { self.images[key] = rendered }
            }
        }
    }

    private nonisolated static func render(asset: CursorAssets.Asset?, height: CGFloat) -> NSImage? {
        guard let asset else { return nil }
        let extent = asset.image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = height * 2 / max(extent.width, extent.height)
        let scaled = asset.image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
    }
}

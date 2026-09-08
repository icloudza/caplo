import CoreGraphics
import CoreImage
import EditingCore
import Foundation
import ImageIO

/// 光标素材：内置三套主题（PNG 由随包的 SVG 光栅化，许可证一同打包）和用户绘制的四十款样式。
/// 全部按需加载：第一次用到某一张才解码、扫透明边、裁剪，结果按名字缓存，渲染器逐帧取的只是一次字典查找。
/// 早先是一次性读全部四十张并各建一个 CIContext 回读位图扫描，首次进入光标面板要一秒多，还会把并发线程池和合成器一起卡住。
enum CursorAssets {
    /// CIImage 是不可变的配方对象，可安全跨线程传递。
    struct Asset: @unchecked Sendable { let image: CIImage; let hotspot: CGPoint }

    /// 素材缓存：加锁的字典，首次取某一键时在锁内加载（单张解码加扫描约一两毫秒），找不到的也记住，不反复找文件。
    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var assets: [String: Asset?] = [:]
        /// 已加载（含找不到）的素材数，测试用来确认按需加载。
        var loadedCount: Int { lock.withLock { assets.count } }
        func asset(_ key: String, load: () -> Asset?) -> Asset? {
            lock.withLock {
                if let cached = assets[key] { return cached }
                let loaded = load()
                assets[key] = .some(loaded)
                return loaded
            }
        }
    }
    static let store = Store()

    private static let files: [PointerShape: String] = [
        .arrow: "arrow", .pointer: "pointer", .text: "text", .grab: "open-hand", .grabbing: "closed-hand",
        .crosshair: "crosshair", .resizeEW: "resize-ew", .resizeNS: "resize-ns", .resizeNESW: "resize-nesw",
        .resizeNWSE: "resize-nwse", .notAllowed: "not-allowed", .alias: "alias", .copy: "copy", .contextMenu: "context-menu"
    ]

    /// 用户绘制的样式：按 id 取 PNG 与目录里的热点，裁掉透明边后热点随之换算；只有箭头形状会用到。
    static func custom(_ id: String) -> Asset? { custom(id, in: store) }
    static func custom(_ id: String, in store: Store) -> Asset? {
        store.asset("custom/\(id)") {
            guard let style = CursorStyle.style(id: id), let image = decode(style.resource) else { return nil }
            return cropped(CIImage(cgImage: image), bounds: visibleBounds(image, flipped: true), hotspot: CGPoint(x: style.hotspotX, y: style.hotspotY))
        }
    }

    static func asset(style: PointerEffects.Style, shape: PointerShape) -> Asset? { asset(style: style, shape: shape, in: store) }
    static func asset(style: PointerEffects.Style, shape: PointerShape, in store: Store) -> Asset? {
        let theme = style == .macos ? "macos" : style == .minimal && shape == .arrow ? "minimal" : "tahoe"
        let name = "\(theme)-\(files[shape] ?? "arrow")"
        return store.asset("\(style.rawValue)/\(name)") {
            guard let decoded = decode(name) else { return nil }
            var image = CIImage(cgImage: decoded)
            // 内置主题的热点常数是按"行号当 y"的旧口径调出来的，这里保持不翻转，见 visibleBounds。
            let bounds = visibleBounds(decoded, flipped: false)
            let hotspot: CGPoint
            if theme == "minimal" { hotspot = CGPoint(x: 0.1, y: 0.05) }
            else if theme == "macos" {
                switch shape {
                case .arrow: hotspot = CGPoint(x: 0.34, y: 0.24)
                case .pointer: hotspot = CGPoint(x: 0.39, y: 0.26)
                case .notAllowed, .copy: hotspot = CGPoint(x: 0.23, y: 0)
                case .alias: hotspot = CGPoint(x: 0.63, y: 0.29)
                case .contextMenu: hotspot = CGPoint(x: 0.26, y: 0.21)
                default: hotspot = CGPoint(x: 0.5, y: 0.5)
                }
            } else {
                switch shape {
                case .arrow: hotspot = CGPoint(x: 0.14, y: 0.06)
                case .pointer: hotspot = CGPoint(x: 0.4, y: 0.1)
                case .text: hotspot = CGPoint(x: 0.5, y: 0.44)
                case .grab: hotspot = CGPoint(x: 0.55, y: 0.57)
                case .grabbing, .resizeNESW: hotspot = CGPoint(x: 0.5, y: 0.46)
                case .resizeNS: hotspot = CGPoint(x: 0.5, y: 0.49)
                case .resizeNWSE: hotspot = CGPoint(x: 0.51, y: 0.46)
                case .notAllowed, .copy: hotspot = CGPoint(x: 0.23, y: 0)
                case .alias: hotspot = CGPoint(x: 0.63, y: 0.29)
                case .contextMenu: hotspot = CGPoint(x: 0.12, y: 0.05)
                default: hotspot = CGPoint(x: 0.5, y: 0.5)
                }
            }
            if style == .inverted { image = image.applyingFilter("CIColorInvert") }
            let mapped = CGPoint(x: (hotspot.x * image.extent.width - bounds.minX) / bounds.width,
                                 y: (image.extent.height * (1 - hotspot.y) - bounds.minY) / bounds.height)
            image = image.cropped(to: bounds).transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            return Asset(image: image, hotspot: CGPoint(x: mapped.x, y: 1 - mapped.y))
        }
    }

    /// 从资源包解码一张 PNG（解码结果随 CGImage 缓存，渲染时不再反复解码）。
    private static func decode(_ name: String) -> CGImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"), let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
    }

    // 透明边裁剪：按 alpha 找可见范围，热点随裁剪平移。
    /// 把 PNG 画到 RGBA8 位图上逐像素找 alpha（CPU，一张 384² 不到一毫秒；位图第一行是图像顶部）。
    /// `flipped` 为真把行号翻成 Core Image 的 y 向上坐标（用户样式四周留白 10–18 点，裁错到镜像位置会切掉尖端）；
    /// 为假沿用旧的"行号当 y"口径——内置主题画布几乎被素材填满，热点常数是按它调出来的，不改。
    private static func visibleBounds(_ image: CGImage, flipped: Bool) -> CGRect {
        let width = image.width, height = image.height
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return extent }
        context.draw(image, in: extent)
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return extent }
        var left = width, right = -1, topRow = height, bottomRow = -1
        for row in 0..<height { for x in 0..<width where bytes[(row * width + x) * 4 + 3] > 8 {
            left = min(left, x); right = max(right, x); topRow = min(topRow, row); bottomRow = max(bottomRow, row)
        } }
        guard right >= left, bottomRow >= topRow else { return extent }
        return CGRect(x: left, y: flipped ? height - bottomRow - 1 : topRow, width: right - left + 1, height: bottomRow - topRow + 1)
    }

    /// 裁掉透明边，热点（相对整图、y 向下）换算到裁后图像。
    private static func cropped(_ image: CIImage, bounds: CGRect, hotspot: CGPoint) -> Asset {
        let mapped = CGPoint(x: (hotspot.x * image.extent.width - bounds.minX) / bounds.width,
                             y: (image.extent.height * (1 - hotspot.y) - bounds.minY) / bounds.height)
        let trimmed = image.cropped(to: bounds).transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        // 指尖正好落在最上一行时会因舍入差出万分之几，夹回 0…1。
        return Asset(image: trimmed, hotspot: CGPoint(x: min(1, max(0, mapped.x)), y: min(1, max(0, 1 - mapped.y))))
    }
}

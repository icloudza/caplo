import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 桌面壁纸：取当前那一张，并把它按不超过 3840 宽转成 HEIC 收进工程包。
/// 新工程默认就用它当背景——录屏摆在自己的桌面上最像"这台机器上的东西"，
/// 比从一堆渐变里随便挑一个更贴。挑不到就退回渐变，绝不因此让工程打不开。
public enum DesktopWallpaper {
    /// 收进工程包时的最长边。原图动辄六千宽几十兆，全尺寸复制进去毫无必要。
    public static let maximumEdge = 3840

    /// 当前桌面壁纸文件。取主屏那一张；动态壁纸是一份多帧 HEIC，解码时取第一帧（浅色）。
    @MainActor public static func currentURL() -> URL? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 解码并缩到不超过 `maximumPixelSize`；动态壁纸取第一帧。
    public static func decode(_ url: URL, maximumPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return ImageDownsampler.image(from: source, maximumPixelSize: maximumPixelSize)
    }

    /// 位图写成 HEIC 收进工程包，返回工程内相对路径。
    public static func importImage(_ image: CGImage, into project: URL) throws -> String {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("caplo-backdrop-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw ProjectError.invalid("无法写入壁纸。")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ProjectError.invalid("无法写入壁纸。") }
        return try ProjectStorage.importBackground(from: temporary, into: project)
    }

    /// 一张壁纸文件收进工程包。
    public static func importWallpaper(_ url: URL, into project: URL) throws -> String {
        guard let image = decode(url, maximumPixelSize: maximumEdge) else { throw ProjectError.invalid("无法读取这张壁纸。") }
        return try importImage(image, into: project)
    }
}

/// 按最长边上限解码位图（顺带应用 EXIF 方向）。
public enum ImageDownsampler {
    /// 原图本来就不超过上限时不传上限、按原尺寸解码：上限大于原图时 ImageIO 每次都会打一条
    /// "kCGImageSourceThumbnailMaxPixelSize … is larger than image-dimension" 错误日志（3600×2592 的壁纸配 3840 上限就是这样）。
    public static func image(from source: CGImageSource, maximumPixelSize: Int) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        if width <= 0 || height <= 0 || max(width, height) > maximumPixelSize {
            options[kCGImageSourceThumbnailMaxPixelSize] = maximumPixelSize
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

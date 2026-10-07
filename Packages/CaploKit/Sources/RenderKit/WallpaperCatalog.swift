import Foundation

/// 随应用内置的壁纸：两个系列各九张，3840×2160 WebP（由用户提供的 5K PNG 用 cwebp 缩到导出上限 4K、q92 + sharp_yuv 压制，
/// 单张约 300 KB、肉眼与原图无差别），打在 RenderKit 资源包里，按 `系列-序号.webp` 命名；选中时原样复制进工程，不再转码。
public enum WallpaperSeries: String, CaseIterable, Sendable, Identifiable {
    case echoes, silk
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .echoes: String(localized: "色彩回响")
        case .silk: String(localized: "暗夜流丝")
        }
    }
    static let count = 9
}

public struct BundledWallpaper: Identifiable, Hashable, Sendable {
    public let series: WallpaperSeries
    public let number: Int
    public var id: String { "\(series.rawValue)-\(String(format: "%02d", number))" }
    public var title: String { "\(series.title) \(number)" }
    /// 资源包里的文件；缺失时为 nil（面板会跳过，不会崩）。
    public var url: URL? { Bundle.module.url(forResource: id, withExtension: "webp") }
}

public enum WallpaperCatalog {
    public static func wallpapers(in series: WallpaperSeries) -> [BundledWallpaper] {
        (1...WallpaperSeries.count).map { BundledWallpaper(series: series, number: $0) }
    }
    public static var all: [BundledWallpaper] { WallpaperSeries.allCases.flatMap(wallpapers(in:)) }
}

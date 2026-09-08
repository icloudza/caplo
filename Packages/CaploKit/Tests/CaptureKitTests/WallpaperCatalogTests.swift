import Foundation
import ImageIO
import Testing
@testable import RenderKit

/// 内置壁纸：两个系列各九张都在资源包里，3840×2160 WebP，ImageIO 能解码，单张不超过 1 MB。
@Test func bundledWallpapersArePresentAndDecodable() throws {
    #expect(WallpaperSeries.allCases.count == 2)
    #expect(WallpaperCatalog.all.count == 18)
    #expect(Set(WallpaperCatalog.all.map(\.id)).count == 18)
    for wallpaper in WallpaperCatalog.all {
        let url = try #require(wallpaper.url, Comment(rawValue: wallpaper.id))
        #expect(url.pathExtension == "webp")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        #expect(properties["PixelWidth"] as? Int == 3840 && properties["PixelHeight"] as? Int == 2160, Comment(rawValue: wallpaper.id))
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size > 50_000 && size < 1_000_000)
    }
    #expect(WallpaperSeries.echoes.title == "色彩回响" && WallpaperSeries.silk.title == "暗夜流丝")
}

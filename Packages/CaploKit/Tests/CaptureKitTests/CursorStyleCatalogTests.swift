import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Testing
@testable import RenderKit

/// 用户绘制的光标样式：四组各十款都在资源包里、4× PNG、热点在画布内；裁边后的热点位置符合各组规则。
@Test func drawnCursorStylesArePresentWithSensibleHotspots() throws {
    #expect(CursorStyle.all.count == 40)
    #expect(Set(CursorStyle.all.map(\.id)).count == 40)
    for group in CursorStyle.Group.allCases { #expect(CursorStyle.styles(in: group).count == 10) }
    for style in CursorStyle.all {
        let url = try #require(Bundle.module.url(forResource: style.resource, withExtension: "png"), Comment(rawValue: style.id))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        #expect(properties["PixelWidth"] as? Int == 384 && properties["PixelHeight"] as? Int == 384, Comment(rawValue: style.id))
        #expect((0...1).contains(style.hotspotX) && (0...1).contains(style.hotspotY))
        #expect(!style.title.isEmpty)
        let asset = try #require(CursorAssets.custom(style.id), Comment(rawValue: style.id))
        #expect(asset.image.extent.width > 0 && asset.image.extent.height > 0)
        #expect((0...1).contains(asset.hotspot.x) && (0...1).contains(asset.hotspot.y), Comment(rawValue: "\(style.id) \(asset.hotspot)"))
        // 裁边必须是紧的：裁后图像的最上一行和最下一行都有可见像素（裁错到镜像位置时上行会是空的）。
        let coverage = try #require(rowCoverage(asset.image))
        #expect(coverage.top && coverage.bottom, Comment(rawValue: style.id))
    }
    // 箭头尖端在裁后图像的左上角附近；圆片热点在正中；手形指尖在上缘。
    let arrow = try #require(CursorAssets.custom("1-01"))
    #expect(arrow.hotspot.x < 0.12 && arrow.hotspot.y < 0.12)
    let disc = try #require(CursorAssets.custom("4-04"))
    #expect(abs(disc.hotspot.x - 0.5) < 0.05 && abs(disc.hotspot.y - 0.5) < 0.05)
    let hand = try #require(CursorAssets.custom("3-01"))
    #expect(hand.hotspot.y < 0.08 && hand.hotspot.x > 0.15 && hand.hotspot.x < 0.6)
    #expect(CursorAssets.custom("9-99") == nil)
}

/// 渲染成位图后检查首尾两行是否有可见像素。
private func rowCoverage(_ image: CIImage) -> (top: Bool, bottom: Bool)? {
    let width = Int(image.extent.width), height = Int(image.extent.height)
    guard width > 0, height > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    CIContext().render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    func visible(row: Int) -> Bool { (0..<width).contains { bytes[(row * width + $0) * 4 + 3] > 8 } }
    return (visible(row: 0), visible(row: height - 1))
}

/// 素材按需加载：取一款只解码这一款，再取命中缓存；内置主题同样按需；找不到的也记住。
@Test func cursorAssetsLoadLazilyAndCache() throws {
    let store = CursorAssets.Store()
    let first = try #require(CursorAssets.custom("1-01", in: store))
    #expect(store.loadedCount == 1)
    #expect(CursorAssets.custom("1-01", in: store)?.image === first.image)
    #expect(store.loadedCount == 1)
    #expect(CursorAssets.asset(style: .tahoe, shape: .arrow, in: store) != nil)
    #expect(store.loadedCount == 2)
    #expect(CursorAssets.custom("9-99", in: store) == nil)
    #expect(store.loadedCount == 3)
}


import Foundation
import CryptoKit
import CoreGraphics
import ImageIO

/// 随工程保存的真实光标。图像内容与热点一起参与标识，避免同图不同热点被错误去重。
public struct CapturedCursor: Codable, Equatable, Sendable {
    public let png: Data
    public let width: Int
    public let height: Int
    public let hotspotX: Double
    public let hotspotY: Double
    public let scale: Double
    public init(png: Data, width: Int, height: Int, hotspotX: Double, hotspotY: Double, scale: Double) {
        self.png = png; self.width = width; self.height = height
        self.hotspotX = hotspotX; self.hotspotY = hotspotY; self.scale = scale
    }
    public var id: String {
        var data = png
        data.append(Data("|\(width)|\(height)|\(hotspotX)|\(hotspotY)|\(scale)".utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    /// 可见部分的点高度：解码 PNG 按 alpha 找最上与最下的可见行。系统光标图像四周带透明留白，按整图算会把"系统大小"算大。
    public var visibleHeightPoints: Double? {
        guard scale > 0, let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var top = height, bottom = -1
        for y in 0..<height { for x in 0..<width where data[(y * width + x) * 4 + 3] > 8 { top = min(top, y); bottom = max(bottom, y) } }
        guard bottom >= top else { return nil }
        return Double(bottom - top + 1) / scale
    }
    public var isValid: Bool {
        !png.isEmpty && png.count <= 1_048_576 && (1...512).contains(width) && (1...512).contains(height)
        && scale.isFinite && (0.25...8).contains(scale)
        && hotspotX.isFinite && hotspotY.isFinite && (0...Double(width)).contains(hotspotX) && (0...Double(height)).contains(hotspotY)
    }
}

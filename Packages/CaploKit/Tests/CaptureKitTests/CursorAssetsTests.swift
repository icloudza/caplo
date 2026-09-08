import Testing
import CoreImage
import Foundation
import ImageIO
import EditingCore
@testable import RenderKit

@Test func importedCursorAssetsContainPixelsAndPreserveHotspots() throws {
    let context = CIContext()
    for style in [PointerEffects.Style.macos, .tahoe, .inverted, .minimal] {
        for shape in PointerShape.allCases {
            let asset = try #require(CursorAssets.asset(style: style, shape: shape))
            #expect(asset.image.extent.height > 0 && asset.image.extent.height <= 256)
            // 裁掉留白后，原先位于透明区的热点可合法落在纹理外。
            #expect(asset.hotspot.x.isFinite && asset.hotspot.y.isFinite)
            let image = try #require(context.createCGImage(asset.image, from: asset.image.extent))
            let data = try #require(image.dataProvider?.data)
            #expect(CFDataGetLength(data) > 256)
            var rgba = [UInt8](repeating: 0, count: 64 * 64 * 4)
            let resized = asset.image.transformed(by: CGAffineTransform(scaleX: 64 / asset.image.extent.width, y: 64 / asset.image.extent.height))
            context.render(resized, toBitmap: &rgba, rowBytes: 64 * 4, bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            #expect(stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] > 128 }.count > 20, "\(style) / \(shape)")
        }
    }
    let modern = try #require(CursorAssets.asset(style: .tahoe, shape: .arrow))
    #expect(modern.image.extent.origin == .zero && modern.image.extent.height < 256)
}

@Test func removedCursorCatalogSettingsFallBackToModernTheme() throws {
    let data = Data(#"{"style":"recordly","assetOverride":"recordly-pointer-1","smoothing":0.7}"#.utf8)
    let effects = try JSONDecoder().decode(PointerEffects.self, from: data)
    #expect(effects.style == .tahoe && effects.smoothing == 0.7)
    let saved = try JSONEncoder().encode(effects)
    #expect(!String(decoding: saved, as: UTF8.self).contains("recordly"))
    #expect(!String(decoding: saved, as: UTF8.self).contains("assetOverride"))
}

@Test func directionalBlurExpandsAlongMotionAndPreservesCursorCenter() throws {
    let context = CIContext()
    var effects = PointerEffects(); effects.style = .tahoe
    var frame = PointerFrame(); frame.position = CGPoint(x: 0.5, y: 0.5)
    let bounds = CGRect(x: 0, y: 0, width: 256, height: 256)
    func moments(_ value: PointerFrame, blur: Double) -> (x: Double, y: Double, vx: Double, vy: Double) {
        var options = effects; options.motionBlur = blur
        let result = PointerRenderer.overlay(frame: value, effects: options, sourceBounds: bounds, transform: .identity, unit: 1, over: CIImage.empty())
        var bytes = [UInt8](repeating: 0, count: 256 * 256 * 4)
        context.render(result, toBitmap: &bytes, rowBytes: 1024, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var mass = 0.0, x = 0.0, y = 0.0, xx = 0.0, yy = 0.0
        for row in 0..<256 { for col in 0..<256 {
            let a = Double(bytes[(row * 256 + col) * 4 + 3])
            mass += a; x += a * Double(col); y += a * Double(row)
            xx += a * Double(col * col); yy += a * Double(row * row)
        } }
        return (x / mass, y / mass, xx / mass - pow(x / mass, 2), yy / mass - pow(y / mass, 2))
    }
    let sharp = moments(frame, blur: 0)
    frame.blurDelta = CGPoint(x: 0.06, y: 0)
    let horizontal = moments(frame, blur: 1)
    frame.blurDelta = CGPoint(x: 0, y: 0.06)
    let vertical = moments(frame, blur: 1)
    #expect(horizontal.vx > sharp.vx + 10 && abs(horizontal.vy - sharp.vy) < 3)
    #expect(vertical.vy > sharp.vy + 10 && abs(vertical.vx - sharp.vx) < 3)
    #expect(abs(horizontal.x - sharp.x) < 1 && abs(vertical.y - sharp.y) < 1)
}

/// 选了自绘样式就画它：底层是"真实光标"（新工程默认）也不能盖过样式，不需要先切到"现代"再选。
@Test func customCursorStyleOverridesCapturedCursor() throws {
    let context = CIContext()
    let bounds = CGRect(x: 0, y: 0, width: 256, height: 256)
    var frame = PointerFrame(); frame.position = CGPoint(x: 0.5, y: 0.5)
    frame.capturedCursor = CapturedCursor(png: try #require(solidPNG(size: 32, red: 0, green: 255, blue: 0)), width: 32, height: 32, hotspotX: 0, hotspotY: 0, scale: 1)
    func render(_ style: PointerEffects.Style, custom: String?) -> [UInt8] {
        var effects = PointerEffects(); effects.style = style; effects.cursorStyle = custom
        let image = PointerRenderer.overlay(frame: frame, effects: effects, sourceBounds: bounds, transform: .identity, unit: 1, over: CIImage.empty())
        var bytes = [UInt8](repeating: 0, count: 256 * 256 * 4)
        context.render(image, toBitmap: &bytes, rowBytes: 1024, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes
    }
    func greenPixels(_ bytes: [UInt8]) -> Int {
        stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0 + 3] > 128 && bytes[$0 + 1] > 200 && bytes[$0] < 60 && bytes[$0 + 2] < 60 }.count
    }
    let captured = render(.captured, custom: nil)
    let styledOnCaptured = render(.captured, custom: "1-04")
    let styledOnModern = render(.tahoe, custom: "1-04")
    #expect(greenPixels(captured) > 200, "没选样式时画真实光标（纯绿方块）")
    #expect(greenPixels(styledOnCaptured) == 0, "选了样式就不能再画真实光标")
    #expect(styledOnCaptured == styledOnModern, "样式画面与底层是现代还是真实光标无关")
    #expect(stride(from: 3, to: styledOnCaptured.count, by: 4).filter { styledOnCaptured[$0] > 128 }.count > 100, "样式本身画出来了")
}

/// 生成一张纯色方形 PNG。
private func solidPNG(size: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> Data? {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.setFillColor(CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}


import CoreImage
import CoreGraphics
import Foundation
import Testing
import EditingCore
@testable import RenderKit

/// 遮罩渲染的安全契约：被盖住的区域里没有可辨认的边缘，镜头推到 2 倍之后依然没有，
/// 区域之外一个像素都不改，贴着画面边缘也不会吸进黑边，裁切换取景同样遮得住。
private let space = CGColorSpace(name: CGColorSpace.sRGB)!
private let renderContext = CIContext(options: [.workingColorSpace: space])

/// 方格图：高频细节的替身。`cell` 是格子边长，模糊或像素化只要生效就会把格线抹平。
private func checkerboard(width: Int, height: Int, cell: Int = 2) -> CIImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let value: UInt8 = ((x / cell) + (y / cell)) % 2 == 0 ? 255 : 0
            let offset = (y * width + x) * 4
            bytes[offset] = value; bytes[offset + 1] = value; bytes[offset + 2] = value; bytes[offset + 3] = 255
        }
    }
    return CIImage(bitmapData: Data(bytes), bytesPerRow: width * 4,
                   size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: space)
}

/// 渲染成位图。行序自上而下，所以 `luma(x:y:)` 的 y 就是从画面顶端往下数。
private struct Bitmap {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    func luma(x: Int, y: Int) -> Int { Int(bytes[(y * width + x) * 4]) }
    /// 相邻像素亮度差超过 32 的比例。方格原图约等于「1 除以格子边长」，糊掉之后趋近 0。
    /// 用边缘密度而不是平均差值，是因为像素化天然在块边界留下硬边，那不是可辨认的内容。
    func edgeDensity(in box: CGRect) -> Double {
        var edges = 0, count = 0
        let x0 = max(0, Int(box.minX)), x1 = min(width - 1, Int(box.maxX))
        let y0 = max(0, Int(box.minY)), y1 = min(height, Int(box.maxY))
        guard x1 > x0 + 1, y1 > y0 else { return 0 }
        for y in y0..<y1 {
            for x in x0..<(x1 - 1) {
                if abs(luma(x: x, y: y) - luma(x: x + 1, y: y)) > 32 { edges += 1 }
                count += 1
            }
        }
        return count > 0 ? Double(edges) / Double(count) : 0
    }
}

private func pixels(_ image: CIImage, bounds: CGRect) -> Bitmap {
    let width = Int(bounds.width), height = Int(bounds.height)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    renderContext.render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: bounds, format: .RGBA8, colorSpace: space)
    return Bitmap(bytes: bytes, width: width, height: height)
}

private func sensitiveEdit(effect: MaskSegment.Effect, width: Double = 0.4, height: Double = 0.4) -> VideoEdit {
    var edit = VideoEdit(duration: 4)
    edit.layout.padding = 0; edit.layout.cornerRadius = 0; edit.layout.shadow = false
    edit.addMask(MaskSegment(start: 0, duration: 4, x: 0.5, y: 0.5, width: width, height: height, effect: effect))
    return edit
}

@Test(arguments: [MaskSegment.Effect.blur, .pixelate])
func maskDestroysDetailInsideAndTouchesNothingOutside(effect: MaskSegment.Effect) {
    // 预编译的 Metal 内核要随包带着、建得出来：读不到时会静默退回已弃用的运行时编译内核（新系统上可能没有），
    // 卡片圆角、阴影与玻璃光标随之失效，平时却看不出来。
    #expect(MetalKernels.kernel("liquidGlass") != nil && MetalKernels.colorKernel("cardCoverage") != nil && MetalKernels.colorKernel("cardShadow") != nil,
            "资源包里的 CaploKernels.metallib 缺失或建不出内核")
    let source = checkerboard(width: 1280, height: 720)
    let edit = sensitiveEdit(effect: effect)
    let masked = pixels(MaskRenderer.apply(edit.activeMasks(at: 2), to: source), bounds: source.extent)
    let plain = pixels(source, bounds: source.extent)
    // 中心 30 % 完全落在遮罩里；左上角完全在外面。
    let inside = CGRect(x: 448, y: 252, width: 384, height: 216)
    #expect(plain.edgeDensity(in: inside) > 0.4, "原图只有 \(plain.edgeDensity(in: inside)) 的边缘密度，这个测试测不出东西")
    #expect(masked.edgeDensity(in: inside) < 0.06, "\(effect) 之后中心还剩 \(masked.edgeDensity(in: inside)) 的边缘密度")
    let outside = CGRect(x: 8, y: 8, width: 200, height: 120)
    #expect(abs(masked.edgeDensity(in: outside) - plain.edgeDensity(in: outside)) < 0.001)
    // 区域外要求逐像素一致，不能因为滤镜的求值范围而整体偏色。
    var changed = 0
    for y in 0..<80 { for x in 0..<160 where masked.luma(x: x, y: y) != plain.luma(x: x, y: y) { changed += 1 } }
    #expect(changed == 0, "遮罩外有 \(changed) 个像素被改动了")
}


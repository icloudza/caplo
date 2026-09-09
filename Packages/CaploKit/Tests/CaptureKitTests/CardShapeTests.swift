import CoreImage
import Testing
import EditingCore
@testable import RenderKit

/// 卡片距离场：内核在运行时编译成功；覆盖率在角外为 0、内部为 1、边缘半覆盖；阴影只在形状外衰减；
/// 720p / 1080p / 4K 三档下几何按比例一致（分辨率无关是契约）。
private func bitmap(_ image: CIImage, bounds: CGRect) -> [UInt8] {
    let width = Int(bounds.width), height = Int(bounds.height)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    CIContext().render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return bytes
}
private func alpha(_ bytes: [UInt8], x: Int, y: Int, width: Int, height: Int) -> Int {
    // Core Image 位图行序自上而下，y 向上的坐标要翻转。
    Int(bytes[((height - 1 - y) * width + x) * 4 + 3])
}

@Test func cardKernelsCompileAndCoverageFollowsTheRoundedShape() throws {
    #expect(CardShape.isAvailable)
    // 下边落在 80.5：第 80 行像素正好一半在形状内，覆盖率应约 50%；第 79 行在外、第 81 行在内。
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 300), rect = CGRect(x: 100, y: 80.5, width: 200, height: 140)
    let coverage = try #require(CardShape.coverage(rect: rect, radius: 40, bounds: bounds))
    let bytes = bitmap(coverage, bounds: bounds)
    #expect(alpha(bytes, x: 102, y: 83, width: 400, height: 300) < 8)
    #expect(alpha(bytes, x: 200, y: 150, width: 400, height: 300) > 250)
    let edge = alpha(bytes, x: 200, y: 80, width: 400, height: 300)
    #expect(edge > 100 && edge < 160, "半覆盖像素 \(edge)")
    #expect(alpha(bytes, x: 200, y: 79, width: 400, height: 300) < 8 && alpha(bytes, x: 200, y: 81, width: 400, height: 300) > 247)
    #expect(alpha(bytes, x: 20, y: 20, width: 400, height: 300) == 0)
}

@Test func cardShadowFallsOffOutsideTheShapeAndRespectsOffset() throws {
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 300), rect = CGRect(x: 100, y: 100, width: 200, height: 100)
    let shadow = try #require(CardShape.shadow(rect: rect, radius: 12, blur: 20, offset: 10, opacity: 0.6, bounds: bounds))
    let bytes = bitmap(shadow, bounds: bounds)
    // 形状向下偏 10：下缘外 6 像素处仍有阴影，上缘外同距离处更淡；远处为 0；内部接近满不透明度 0.6。
    let below = alpha(bytes, x: 200, y: 84, width: 400, height: 300), above = alpha(bytes, x: 200, y: 206, width: 400, height: 300)
    #expect(below > 40 && below > above)
    #expect(alpha(bytes, x: 200, y: 20, width: 400, height: 300) == 0)
    #expect(abs(alpha(bytes, x: 200, y: 140, width: 400, height: 300) - 153) < 6)
}

@Test func screenGeometryScalesExactlyWithOutputResolution() {
    var edit = VideoEdit(duration: 4)
    edit.layout.padding = 40; edit.layout.cornerRadius = 12; edit.layout.shadow = true
    let source = CGSize(width: 1920, height: 1080)
    let reference = SceneRenderer.geometry(edit: edit, sourceSize: source, size: CGSize(width: 1920, height: 1080))
    for size in [CGSize(width: 1280, height: 720), CGSize(width: 3840, height: 2160)] {
        let geometry = SceneRenderer.geometry(edit: edit, sourceSize: source, size: size)
        let k = size.width / 1920
        #expect(abs(geometry.rect.minX - reference.rect.minX * k) < 0.001 && abs(geometry.rect.width - reference.rect.width * k) < 0.001)
        #expect(abs(geometry.rect.minY - reference.rect.minY * k) < 0.001 && abs(geometry.rect.height - reference.rect.height * k) < 0.001)
        #expect(abs(geometry.radius - reference.radius * k) < 0.001)
    }
}

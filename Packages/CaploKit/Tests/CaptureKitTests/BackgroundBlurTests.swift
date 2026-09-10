import CoreImage
import Foundation
import Testing
import EditingCore
@testable import RenderKit

private let blurSpace = CGColorSpace(name: CGColorSpace.sRGB)!

/// 背景模糊：只作用在背景图上，糊完不能把四周拉淡露出灰边。
struct BackgroundBlurTests {
    private let size = CGSize(width: 240, height: 135)

    /// 左黑右白的背景图，交界处糊开就能量出来。
    private func source() -> CIImage {
        let bounds = CGRect(x: 0, y: 0, width: 480, height: 270)
        let dark = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 240, height: 270))
        let light = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 240, y: 0, width: 240, height: 270))
        return light.composited(over: dark).cropped(to: bounds)
    }

    private func pixels(_ image: CIImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
        CIContext().render(image, toBitmap: &bytes, rowBytes: Int(size.width) * 4,
                           bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: blurSpace)
        return bytes
    }
    private func red(_ bytes: [UInt8], _ x: Int, _ y: Int) -> Int { Int(bytes[(y * Int(size.width) + x) * 4]) }

    @Test func blurSoftensTheImageAndLeavesNoWashedOutEdge() {
        var layout = CanvasLayout()
        let sharp = pixels(SceneRenderer.background(layout, image: source(), size: size))
        layout.backgroundBlur = 60
        let soft = pixels(SceneRenderer.background(layout, image: source(), size: size))
        let middle = Int(size.height / 2), seam = Int(size.width / 2)

        // 没糊：交界一步到位，隔壁两列一黑一白。
        #expect(red(sharp, seam - 3, middle) < 20 && red(sharp, seam + 3, middle) > 235)
        // 糊过：同样两列被抹成中间调，明暗差明显收窄。
        let softStep = abs(red(soft, seam + 3, middle) - red(soft, seam - 3, middle))
        #expect(softStep < 120, "交界没糊开，明暗差还有 \(softStep)")

        // 四角不能被透明像素拉淡：左上角仍是黑的，右上角仍是白的。
        #expect(red(soft, 1, middle) < 40, "左边缘被糊淡了（\(red(soft, 1, middle))）")
        #expect(red(soft, Int(size.width) - 2, middle) > 215, "右边缘被糊淡了（\(red(soft, Int(size.width) - 2, middle))）")

        // 模糊为 0 时一个滤镜都不该加：结果与不设模糊逐像素相同。
        var none = CanvasLayout(); none.backgroundBlur = 0
        #expect(pixels(SceneRenderer.background(none, image: source(), size: size)) == sharp)
    }

    /// 渐变不走模糊这条路：糊了还是同一片渐变，白花 GPU。
    @Test func gradientsIgnoreTheBlur() {
        var layout = CanvasLayout(); layout.background = .iris
        let plain = pixels(SceneRenderer.background(layout, image: nil, size: size))
        layout.backgroundBlur = 100
        #expect(pixels(SceneRenderer.background(layout, image: nil, size: size)) == plain)
    }
}

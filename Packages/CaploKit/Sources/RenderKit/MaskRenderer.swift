import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import EditingCore

/// 把区域遮罩画到录制画面上。
///
/// 只处理"源画面"这一层，而且在聚焦变换之前：遮罩因此贴在内容上，镜头推近时它跟着内容一起被放大，
/// 不会因为相机移动而露出底下的东西。强度也定义在内容像素上（以 1080 为参考高度），
/// 所以 3 倍推近之后模糊看起来更大而不是更弱——把强度按输出尺寸算是这个功能最典型的致命错误。
///
/// 预览和导出共用这一个实现，`SceneRenderer.frame` 是唯一的调用点。
public enum MaskRenderer {
    /// 强度的参考高度。1080p 素材上 `amount` 就是像素数，4K 上自动放大一倍。
    public static let referenceHeight: Double = 1080
    /// 像素化块边长相对模糊 σ 的倍数：块要比 σ 大得多才能毁掉同等程度的细节。
    static let pixelBlockRatio: Double = 2

    /// 按顺序把所有遮罩贴到源画面上（后加的盖在上面）。没有遮罩时原样返回，不产生任何滤镜开销。
    public static func apply(_ masks: [MaskState], to image: CIImage) -> CIImage {
        guard !masks.isEmpty, image.extent.width > 0, image.extent.height > 0, image.extent.width.isFinite else { return image }
        var result = image
        for mask in masks { result = apply(mask, to: result, extent: image.extent) }
        return result.cropped(to: image.extent)
    }

    static func apply(_ mask: MaskState, to image: CIImage, extent: CGRect) -> CIImage {
        guard mask.alpha > 0.001 else { return image }
        let rect = self.rect(mask, in: extent)
        guard rect.width > 0.5, rect.height > 0.5 else { return image }
        let unit = extent.height / referenceHeight
        let feather = max(0, mask.feather * unit)
        // 求值范围只比遮罩大一点，避免为了一块小区域去模糊整幅 4K 画面。
        let margin = feather * 3 + 2
        let padded = rect.insetBy(dx: -margin, dy: -margin).intersection(extent.insetBy(dx: -margin, dy: -margin))
        guard !padded.isNull, padded.width > 0, padded.height > 0 else { return image }
        guard let shape = self.shape(mask, rect: rect, feather: feather, unit: unit, bounds: padded) else { return image }
        switch mask.kind {
        case .sensitive:
            // 形状之内换成模糊 / 像素化过的画面，之外保持原样。
            return obscured(image, mask: mask, unit: unit, extent: extent, bounds: padded)
                .applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: shape])
                .cropped(to: extent)
        case .highlight:
            // 高亮反过来：形状之内保持原样，之外压暗。前景背景对调即可，不用去反转遮罩的 alpha。
            let dark = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: min(1, max(0, mask.darkness * mask.alpha)))).cropped(to: extent)
            let dimmed = dark.composited(over: image).cropped(to: extent)
            return image.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: dimmed, kCIInputMaskImageKey: shape])
                .cropped(to: extent)
        }
    }

    /// 遮住内容的那一层：模糊或像素化，都对边缘外推的画面求值，免得贴着画面边界的遮罩把黑边吸进来。
    static func obscured(_ image: CIImage, mask: MaskState, unit: Double, extent: CGRect, bounds: CGRect) -> CIImage {
        let clamped = image.clampedToExtent()
        let amount = max(MaskSegment.amountRange.lowerBound, mask.amount) * unit
        switch mask.effect {
        case .blur:
            return clamped.applyingGaussianBlur(sigma: amount).cropped(to: bounds)
        case .pixelate:
            let filter = CIFilter.pixellate()
            filter.inputImage = clamped
            filter.scale = Float(max(1, amount * pixelBlockRatio))
            // 网格钉在画面原点而不是遮罩中心：遮罩移动时格子相位不变，
            // 否则同一段内容会被不同相位的马赛克拍很多次，逐帧平均能把它还原出来。
            filter.center = CGPoint(x: extent.minX, y: extent.minY)
            return (filter.outputImage ?? clamped).cropped(to: bounds)
        }
    }

    /// 归一化坐标（左上原点）换算成 Core Image 的像素矩形（左下原点）。
    public static func rect(_ mask: MaskState, in extent: CGRect) -> CGRect {
        let width = max(1, min(extent.width * 2, mask.width * extent.width))
        let height = max(1, min(extent.height * 2, mask.height * extent.height))
        let centerX = extent.minX + mask.x * extent.width
        let centerY = extent.minY + (1 - mask.y) * extent.height
        return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }

    /// 形状遮罩：白色代表"这里应用遮罩"。矩形走距离场，椭圆用圆形距离场按轴向拉伸得到。
    /// 距离场内核不可用时退回系统圆角生成器，再不行就退回硬边矩形——敏感遮罩宁可边缘生硬也不能不生效。
    static func shape(_ mask: MaskState, rect: CGRect, feather: Double, unit: Double, bounds: CGRect) -> CIImage? {
        var image: CIImage
        switch mask.shape {
        case .rectangle:
            let radius = min(mask.cornerRadius * unit, min(rect.width, rect.height) / 2)
            image = CardShape.coverage(rect: rect, radius: max(0, radius), bounds: bounds) ?? generated(rect: rect, radius: max(0, radius), bounds: bounds)
        case .ellipse:
            let side = min(rect.width, rect.height)
            let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            let circle = CardShape.coverage(rect: square, radius: side / 2, bounds: square.insetBy(dx: -2, dy: -2))
                ?? generated(rect: square, radius: side / 2, bounds: square.insetBy(dx: -2, dy: -2))
            // 圆按两轴拉成椭圆：先移到原点缩放再移回去，避免缩放同时把位置也带偏。
            let transform = CGAffineTransform(translationX: -rect.midX, y: -rect.midY)
                .concatenating(CGAffineTransform(scaleX: rect.width / side, y: rect.height / side))
                .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
            image = circle.transformed(by: transform)
        }
        if feather > 0.5 { image = image.applyingGaussianBlur(sigma: feather) }
        return image.cropped(to: bounds)
    }

    static func generated(rect: CGRect, radius: Double, bounds: CGRect) -> CIImage {
        let filter = CIFilter.roundedRectangleGenerator()
        filter.extent = rect; filter.radius = Float(radius); filter.color = .white
        if let output = filter.outputImage { return output.cropped(to: bounds) }
        return CIImage(color: .white).cropped(to: rect)
    }
}

import CoreGraphics
import CoreImage
import EditingCore

/// 光标主题、热点、弹跳、速度摆动和方向性运动模糊共用这一合成路径；预览与导出效果一致。
enum PointerRenderer {
    private static let arrow = texture(width: 40, height: 50) { context in
        context.translateBy(x: 0, y: 50); context.scaleBy(x: 1, y: -1)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 5, y: 5))
        for point in [CGPoint(x: 5, y: 37), CGPoint(x: 14, y: 29), CGPoint(x: 21, y: 44), CGPoint(x: 27, y: 41), CGPoint(x: 20, y: 27), CGPoint(x: 32, y: 27)] { path.addLine(to: point) }
        path.closeSubpath(); context.addPath(path)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.setStrokeColor(CGColor(gray: 0.08, alpha: 1))
        context.setLineWidth(2); context.setLineJoin(.round); context.drawPath(using: .fillStroke)
    }
    private static let ring = texture(width: 128, height: 128) { context in
        context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.setLineWidth(5)
        context.strokeEllipse(in: CGRect(x: 5, y: 5, width: 118, height: 118))
    }

    private static let disc = texture(width: 128, height: 128) { context in
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 2, y: 2, width: 124, height: 124))
    }

    static func overlay(frame: PointerFrame, effects: PointerEffects, sourceBounds: CGRect, transform: CGAffineTransform, unit: Double, over screen: CIImage) -> CIImage {
        func point(_ position: CGPoint) -> CGPoint {
            CGPoint(x: sourceBounds.minX + sourceBounds.width * position.x, y: sourceBounds.minY + sourceBounds.height * (1 - position.y)).applying(transform)
        }
        var result = screen
        let tint: (Double, Double, Double)
        switch effects.tint { case .violet: tint = (0.45, 0.3, 1); case .blue: tint = (0.1, 0.65, 1); case .yellow: tint = (1, 0.75, 0.1) }
        for click in frame.clicks {
            let center = point(click.position), radius = (9 + 22 * click.progress) * unit * effects.clickScale
            let alpha = (1 - click.progress) * (1 - click.progress)
            let colored = (effects.clickEffect == .spotlight ? disc : ring).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: tint.0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: tint.1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: tint.2, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
            ])
            result = colored.transformed(by: CGAffineTransform(scaleX: radius / 64, y: radius / 64)
                .concatenating(CGAffineTransform(translationX: center.x - radius, y: center.y - radius))).composited(over: result)
        }
        if effects.clickEffect == .echo {
            for click in frame.clicks where click.progress > 0.2 {
                let center = point(click.position), radius = (9 + 22 * (click.progress - 0.2)) * unit * effects.clickScale
                let echo = ring.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: pow(1 - click.progress, 2) * 0.5)])
                result = echo.transformed(by: CGAffineTransform(scaleX: radius / 64, y: radius / 64)
                    .concatenating(CGAffineTransform(translationX: center.x - radius, y: center.y - radius))).composited(over: result)
            }
        }
        if let position = frame.position {
            func glyph(shape: PointerShape, opacity: Double) -> CIImage {
                // 样式只换箭头：其他形状优先用录制时保存的真实光标，没有就用现代主题的同形状素材。
                // 选了自绘样式就画它——新工程的箭头默认是"真实光标"（style == .captured），样式必须能直接盖过它，
                // 不能要求先切到"现代"再选样式。
                let styled = shape == .arrow
                let custom = styled ? effects.cursorStyle.flatMap(CursorAssets.custom) : nil
                let asset = custom ?? (styled ? (effects.style == .original ? nil : CursorAssets.asset(style: effects.style, shape: shape)) : CursorAssets.asset(style: .tahoe, shape: shape))
                let native = styled ? (custom == nil && effects.style == .captured ? frame.capturedCursor : nil) : frame.capturedCursor
                let nativeImage = native.flatMap { CapturedCursorImages.shared.image($0) }
                let image = nativeImage ?? asset?.image ?? arrow
                let hotspot = nativeImage != nil && native != nil
                    ? CGPoint(x: native!.hotspotX / Double(native!.width), y: native!.hotspotY / Double(native!.height))
                    : asset?.hotspot ?? CGPoint(x: 5.0 / 40, y: 5.0 / 50)
                // 真实光标保留系统 point 尺寸；主题光标继续使用统一可见轮廓大小。
                let scale = nativeImage != nil ? unit * effects.cursorScale * frame.scale / native!.scale
                    : 32 * unit * effects.cursorScale * frame.scale / max(image.extent.width, image.extent.height)
                let center = point(position)
                let placement = CGAffineTransform(translationX: -image.extent.width * hotspot.x, y: -image.extent.height * (1 - hotspot.y))
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(rotationAngle: -frame.rotation))
                    .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
                return image.transformed(by: placement).applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
            }
            // 三款玻璃圆片（透明、磨砂、石墨）不贴图：箭头形状时在画面上做一枚 Liquid Glass 透镜，
            // 手指与十字做成同材质的异形玻璃（按轮廓折射，见 LiquidGlass.shaped），其他形状照常用素材。
            let variant = LiquidGlass.isAvailable ? LiquidGlass.Variant(styleID: effects.cursorStyle) : nil
            let glass = variant != nil
            let currentOpacity = frame.opacity * (effects.style == .original ? 1 : frame.shapeMix)
            var lensOpacity = 0.0
            var shapedOpacity: [PointerShape: Double] = [:]
            var cursor: CIImage
            if glass, frame.shape == .arrow { lensOpacity = currentOpacity; cursor = CIImage.empty() }
            else if glass, frame.shape == .pointer || frame.shape == .crosshair { shapedOpacity[frame.shape] = currentOpacity; cursor = CIImage.empty() }
            else { cursor = glyph(shape: frame.shape, opacity: currentOpacity) }
            if effects.style != .original, let previous = frame.previousShape {
                let previousOpacity = frame.opacity * (1 - frame.shapeMix)
                if glass, previous == .arrow { lensOpacity += previousOpacity }
                else if glass, previous == .pointer || previous == .crosshair { shapedOpacity[previous, default: 0] += previousOpacity }
                else {
                    // 两张图都围绕自己的热点放置，交叉淡化时点击位置不漂移。
                    cursor = cursor.applyingFilter("CIAdditionCompositing", parameters: [
                        kCIInputBackgroundImageKey: glyph(shape: previous, opacity: previousOpacity)
                    ])
                }
            }
            if lensOpacity > 0.001 {
                // 与其他样式同一可见大小：外接尺寸 32 点 × 光标大小 × 点击缩放。
                let radius = 16 * unit * effects.cursorScale * frame.scale
                result = LiquidGlass.lens(over: result, center: point(position), radius: radius, opacity: min(1, lensOpacity), variant: variant ?? .clear)
            }
            for (shape, opacity) in shapedOpacity where opacity > 0.001 {
                // 与其他样式同一可见大小。手指用现代主题手形的轮廓、按它的热点摆放（随点击缩放与旋转）；十字围着点击点。
                let size = 32 * unit * effects.cursorScale * frame.scale
                let mask: CIImage
                if shape == .pointer, let asset = CursorAssets.asset(style: .tahoe, shape: .pointer) {
                    let image = asset.image, scale = size / max(image.extent.width, image.extent.height), center = point(position)
                    mask = image.transformed(by: CGAffineTransform(translationX: -image.extent.width * asset.hotspot.x, y: -image.extent.height * (1 - asset.hotspot.y))
                        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                        .concatenating(CGAffineTransform(rotationAngle: -frame.rotation))
                        .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
                } else {
                    mask = LiquidGlass.crosshairMask(center: point(position), size: size)
                }
                result = LiquidGlass.shaped(over: result, mask: mask, size: size, opacity: min(1, opacity), variant: variant ?? .clear)
            }
            // 按速度方向做运动模糊：固定参考帧率、强度 2；Core Image 实现连续核。
            // 只模糊光标层，点击高亮和视频保持清晰；限制快速跳变的最大拖尾。
            let current = point(position)
            let previous = point(CGPoint(x: position.x - frame.blurDelta.x, y: position.y - frame.blurDelta.y))
            let dx = current.x - previous.x, dy = current.y - previous.y
            let magnitude = min(32 * unit, hypot(dx, dy) * effects.motionBlur * 2)
            if magnitude >= 0.5 {
                cursor = cursor.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: magnitude / 2, kCIInputAngleKey: atan2(dy, dx)])
            }
            result = cursor.composited(over: result)
        }
        return result
    }

    private static func texture(width: Int, height: Int, draw: (CGContext) -> Void) -> CIImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.empty() }
        draw(context)
        return context.makeImage().map { CIImage(cgImage: $0) } ?? CIImage.empty()
    }
}

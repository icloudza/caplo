import CoreGraphics
import CoreImage

/// "透明玻璃"光标的 Liquid Glass 透镜：不再贴一张静态 PNG（静态图只能画出一个灰圈，透不出底下的画面），
/// 而是对光标底下的录屏实时做一次光学处理，预览与导出共用：
///
/// - **折射**：中心约放大 43%；外圈 65% 半径是一圈厚玻璃斜面，越靠边越把圈外的画面压进来（最外缘取自约 1.9 倍半径），
///   文字和线条在圈边强烈弯折；斜面里画面被压缩，沿径向取五点平均，不然细字在那里会闪成一圈彩色噪点；
/// - **色散**：只在斜面里把红、蓝通道沿径向错开，边缘出现明显的彩边；
/// - **光**：斜面整体泛白（玻璃厚边的辉光）+ 左上淡光泽；左上内侧一道高光弧、右下一道弱反光；
///   边缘一圈粗亮环，迎光的左上最亮、对角的右下次之（系统 Liquid Glass 的双侧高光）；
///   亮环内侧压暗一圈、背光一侧更重，白底上也看得出玻璃的厚度；
/// - **投影**：圆心略下方一圈柔和的暗影，只在玻璃外缘露出来，让它"浮"在画面上。
///
/// 内核优先用预编译的 Metal 版（`MetalKernels`），读不到时再用下面的 Core Image 内核语言在运行时编译；
/// 两样都失败时 `isAvailable` 为假，调用方退回 PNG 素材。
enum LiquidGlass {
    /// 光标样式表里"透明玻璃"的 ID。
    static let styleID = "4-01"

    /// 圆片组里三款玻璃：同一枚透镜，换折射强度、玻璃颜色和底下画面的清晰度。
    /// - 透明玻璃：原样折射，无色；
    /// - 磨砂圆片：底下画面先糊开（磨砂），折射收弱，蒙一层亮白雾；
    /// - 石墨圆片：深灰烟色玻璃，折射略收，边缘高光照旧，压在浅色画面上也是一枚"实"的深色圆片。
    enum Variant: Equatable {
        case clear, frosted, graphite
        init?(styleID: String?) {
            switch styleID { case "4-01": self = .clear; case "4-02": self = .frosted; case "4-03": self = .graphite; default: return nil }
        }
        var strength: Double { switch self { case .clear: 1; case .frosted: 0.5; case .graphite: 0.75 } }
        /// 玻璃本身的颜色（sRGB）与覆盖程度。
        var tint: CIVector {
            switch self {
            case .clear: CIVector(x: 0, y: 0, z: 0, w: 0)
            case .frosted: CIVector(x: 0.95, y: 0.96, z: 0.98, w: 0.12)
            case .graphite: CIVector(x: 0.15, y: 0.16, z: 0.18, w: 0.62)
            }
        }
        /// 磨砂：透镜底下的画面先按半径糊开（σ 取半径的 0.1 倍：还认得出底下有东西，细节糊掉）。
        var frost: Double { self == .frosted ? 0.1 : 0 }
    }

    private static let source = """
    kernel vec4 liquidGlass(sampler src, vec2 center, float radius, float opacity, float strength, vec4 tint) {
        vec2 p = destCoord();
        vec2 d = p - center;
        float r = length(d);
        float t = clamp(r / radius, 0.0, 1.0);
        vec2 dir = r > 0.0001 ? d / r : vec2(0.0, 0.0);
        vec2 sd = p - (center + vec2(0.0, -0.1 * radius));
        float shadowAlpha = 0.38 * (1.0 - smoothstep(0.84, 1.42, length(sd) / radius));
        vec4 shadow = vec4(0.0, 0.0, 0.0, shadowAlpha);
        float coverage = 1.0 - smoothstep(radius - 0.75, radius + 0.75, r);
        if (coverage <= 0.0) { return shadow * opacity; }
        float rim = smoothstep(0.35, 1.0, t);
        float bend = rim * rim * (3.0 - 2.0 * rim);
        float factor = mix(1.0, 0.7 + 1.2 * bend, strength);
        vec2 base = center + d * factor;
        vec2 step = dir * (0.02 * radius * bend * strength);
        vec4 mid = (sample(src, samplerTransform(src, base - 2.0 * step)) + sample(src, samplerTransform(src, base - step))
                    + sample(src, samplerTransform(src, base)) + sample(src, samplerTransform(src, base + step))
                    + sample(src, samplerTransform(src, base + 2.0 * step))) / 5.0;
        vec2 spread = dir * (0.06 * radius * bend * strength);
        float red = sample(src, samplerTransform(src, base + spread)).r;
        float blue = sample(src, samplerTransform(src, base - spread)).b;
        vec4 glass = vec4(mix(mid.r, red, 0.9), mid.g, mix(mid.b, blue, 0.9), mid.a);
        glass.rgb = mix(glass.rgb, tint.rgb * glass.a, tint.a);
        vec2 light = normalize(vec2(-0.6, 0.8));
        float facing = dot(dir, light);
        vec3 white = vec3(glass.a, glass.a, glass.a);
        float sheen = smoothstep(-0.2, 0.9, dot(d / radius, light)) * 0.12 * (1.0 - 0.5 * t);
        float glow = smoothstep(0.5, 1.0, t);
        glow = glow * glow * 0.42;
        float arc = smoothstep(0.66, 0.84, t) * (1.0 - smoothstep(0.84, 0.92, t)) * pow(max(facing, 0.0), 2.5) * 0.6;
        float bounce = smoothstep(0.7, 0.86, t) * (1.0 - smoothstep(0.86, 0.93, t)) * pow(max(-facing, 0.0), 3.0) * 0.32;
        glass.rgb = mix(glass.rgb, white, min(1.0, sheen + glow + arc + bounce));
        float inner = smoothstep(0.8, 0.92, t) * (1.0 - smoothstep(0.92, 0.97, t));
        glass.rgb = glass.rgb * (1.0 - inner * (0.12 + 0.2 * (0.5 - 0.5 * facing)));
        float ring = smoothstep(0.87, 0.975, t);
        float lit = 0.5 + 0.5 * pow(max(facing, 0.0), 1.1) + 0.6 * pow(max(-facing, 0.0), 1.5);
        glass.rgb = mix(glass.rgb, white, min(1.0, ring * lit));
        vec4 layer = glass * coverage;
        layer = layer + shadow * (1.0 - layer.a);
        return layer * opacity;
    }
    """

    /// Metal 版优先（见 `MetalKernels`）；下面的 CIKL 源码只作兜底，两处公式必须同步。
    private static let kernel: CIKernel? = MetalKernels.kernel("liquidGlass")
        ?? (CIKernel.makeKernels(source: source) as? [CIKernel])?.first { $0.name == "liquidGlass" }

    static var isAvailable: Bool { kernel != nil }

    /// 异形玻璃（手指、十字）：按光标轮廓折射，见 CaploKernels.metal 里的 shapedGlass。两处公式必须同步。
    private static let shapedSource = """
    kernel vec4 shapedGlass(sampler src, sampler mask, sampler height, float scale, float strength, vec4 tint) {
        vec2 p = destCoord();
        float m = sample(mask, samplerTransform(mask, p)).a;
        if (m <= 0.0) { return vec4(0.0); }
        float h = sample(height, samplerTransform(height, p)).a;
        float e = 1.5;
        float hx = sample(height, samplerTransform(height, p + vec2(e, 0.0))).a - sample(height, samplerTransform(height, p - vec2(e, 0.0))).a;
        float hy = sample(height, samplerTransform(height, p + vec2(0.0, e))).a - sample(height, samplerTransform(height, p - vec2(0.0, e))).a;
        vec2 g = vec2(hx, hy);
        float gl = length(g);
        vec2 n = gl > 0.00001 ? g / gl : vec2(0.0, 0.0);
        float rim = 1.0 - smoothstep(0.5, 0.97, h);
        vec2 base = p - n * rim * rim * scale * strength;
        vec4 mid = (sample(src, samplerTransform(src, base)) + sample(src, samplerTransform(src, base + n * 1.2)) + sample(src, samplerTransform(src, base - n * 1.2))) / 3.0;
        vec2 spread = -n * rim * scale * 0.22 * strength;
        float red = sample(src, samplerTransform(src, base + spread)).r;
        float blue = sample(src, samplerTransform(src, base - spread)).b;
        vec4 glass = vec4(mix(mid.r, red, 0.85), mid.g, mix(mid.b, blue, 0.85), mid.a);
        glass.rgb = mix(glass.rgb, tint.rgb * glass.a, tint.a);
        vec2 light = normalize(vec2(-0.6, 0.8));
        float facing = dot(-n, light);
        vec3 white = vec3(glass.a, glass.a, glass.a);
        float glow = rim * rim * 0.32;
        float ring = smoothstep(0.62, 0.95, rim);
        float lit = 0.45 + 0.55 * pow(max(facing, 0.0), 1.2) + 0.5 * pow(max(-facing, 0.0), 1.6);
        glass.rgb = mix(glass.rgb, white, min(1.0, glow + ring * lit * 0.85));
        float inner = smoothstep(0.3, 0.5, rim) * (1.0 - smoothstep(0.5, 0.65, rim));
        glass.rgb = glass.rgb * (1.0 - inner * 0.14);
        return glass * m;
    }
    """
    private static let shapedKernel: CIKernel? = MetalKernels.kernel("shapedGlass")
        ?? (CIKernel.makeKernels(source: shapedSource) as? [CIKernel])?.first { $0.name == "shapedGlass" }

    /// 在 `image` 上按 `mask`（已摆好位置的光标轮廓，只看 alpha）做一块异形玻璃。`size` 是光标的可见大小（像素），
    /// 折射幅度、边缘厚度、投影都按它等比；只在轮廓外接方框附近求值，再盖回原图。
    static func shaped(over image: CIImage, mask: CIImage, size: CGFloat, opacity: Double, variant: Variant) -> CIImage {
        guard let shapedKernel, size > 2, opacity > 0.001, !mask.extent.isEmpty, !mask.extent.isInfinite else { return image }
        let region = mask.extent.insetBy(dx: -size * 0.3, dy: -size * 0.3).integral
        // 厚度：轮廓糊开，边缘约 0.5、往里趋近 1，梯度就是指向里面的法线。
        let height = mask.applyingGaussianBlur(sigma: size * 0.045).cropped(to: region)
        var source = image.extent.isInfinite ? image : image.clampedToExtent()
        if variant.frost > 0 {
            let sigma = size * 0.035
            source = source.cropped(to: region.insetBy(dx: -size * 0.3 - sigma * 3, dy: -size * 0.3 - sigma * 3)).clampedToExtent().applyingGaussianBlur(sigma: sigma)
        }
        guard let layer = shapedKernel.apply(extent: mask.extent.integral, roiCallback: { _, rect in rect.insetBy(dx: -size * 0.4, dy: -size * 0.4) },
                                             arguments: [source, mask, height, size * 0.11, variant.strength, variant.tint]) else { return image }
        // 投影：轮廓略往下挪、糊开、压到三成，只在玻璃外缘露出来。
        let shadow = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.32),
        ]).transformed(by: CGAffineTransform(translationX: 0, y: -size * 0.04)).applyingGaussianBlur(sigma: size * 0.05).cropped(to: region)
        var glass = layer.composited(over: shadow)
        if opacity < 0.999 {
            glass = glass.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: opacity, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: opacity, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: opacity, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
            ])
        }
        return glass.composited(over: image)
    }

    /// 十字的玻璃轮廓：四段加粗的圆头短条围着点击点，中间留空（细线做成玻璃看不出东西）。`size` 是可见大小。
    static func crosshairMask(center: CGPoint, size: CGFloat) -> CIImage {
        let thickness = size * 0.15, length = size * 0.32, gap = size * 0.1
        var image = CIImage.empty()
        for rect in [CGRect(x: center.x - thickness / 2, y: center.y + gap, width: thickness, height: length),
                     CGRect(x: center.x - thickness / 2, y: center.y - gap - length, width: thickness, height: length),
                     CGRect(x: center.x + gap, y: center.y - thickness / 2, width: length, height: thickness),
                     CGRect(x: center.x - gap - length, y: center.y - thickness / 2, width: length, height: thickness)] {
            if let coverage = CardShape.coverage(rect: rect, radius: thickness / 2, bounds: rect.insetBy(dx: -1, dy: -1)) {
                image = coverage.composited(over: image)
            } else {
                let generator = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: rect), "inputRadius": thickness / 2, "inputColor": CIColor.white])
                if let output = generator?.outputImage { image = output.cropped(to: rect).composited(over: image) }
            }
        }
        return image
    }

    /// 在 `image` 上 `center` 处放一枚半径 `radius`（像素）的玻璃透镜，`opacity` 用于光标淡入淡出。
    /// 只在透镜外接方框（含投影）里求值，再盖回原图：整帧不多走一遍。
    static func lens(over image: CIImage, center: CGPoint, radius: CGFloat, opacity: Double, variant: Variant = .clear) -> CIImage {
        guard let kernel, radius > 1, opacity > 0.001 else { return image }
        // 投影圆心下移 0.1 倍半径、淡到 1.42 倍半径为止，方框取 1.55 倍才不会在底边切出硬边。
        let reach = radius * 1.55
        let extent = CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2).integral
        // 采样落在画面外时取边缘像素，透镜贴着画面边缘时不会把透明区折射进来。
        // 斜面最外缘从约 1.9 倍半径处取样，加上径向平均与色散向外最多偏约 1.0 倍半径，取样范围外扩 1.05 倍半径。
        var source = image.extent.isInfinite ? image : image.clampedToExtent()
        // 磨砂：只糊透镜取样会碰到的那一块（外扩到取样范围再加模糊半径），整帧不糊。
        if variant.frost > 0 {
            let sigma = radius * variant.frost
            source = source.cropped(to: extent.insetBy(dx: -radius * 1.05 - sigma * 3, dy: -radius * 1.05 - sigma * 3))
                .clampedToExtent().applyingGaussianBlur(sigma: sigma)
        }
        guard let layer = kernel.apply(extent: extent, roiCallback: { _, rect in rect.insetBy(dx: -radius * 1.05, dy: -radius * 1.05) },
                                       arguments: [source, CIVector(x: center.x, y: center.y), radius, opacity, variant.strength, variant.tint]) else { return image }
        return layer.composited(over: image)
    }

    /// 样式格里的预览：几行浅灰"文字条"上放一枚透镜，看得出折射把横线弯过去的样子。
    static func preview(size: CGFloat, variant: Variant = .clear) -> CIImage {
        let side = max(16, size)
        var lines = CIImage.empty()
        let gray = CIImage(color: CIColor(red: 0.78, green: 0.8, blue: 0.86, alpha: 1))
        for (index, width) in [0.78, 0.6, 0.86, 0.5, 0.7].enumerated() {
            let y = side * (0.16 + 0.17 * Double(index))
            let bar = gray.cropped(to: CGRect(x: side * 0.08, y: y, width: side * width, height: side * 0.07))
            lines = bar.composited(over: lines)
        }
        // 透镜只折射底下的东西：垫一块深色底，高光与折射才有对象（样式格本身也是深色）。
        let backdrop = CIImage(color: CIColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1))
        let canvas = lines.composited(over: backdrop).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let lensed = lens(over: canvas, center: CGPoint(x: side * 0.5, y: side * 0.5), radius: side * 0.34, opacity: 1, variant: variant).cropped(to: bounds)
        // 底板切成圆角，放进样式格里像一小块屏幕，而不是一块硬边方片。
        guard let mask = CardShape.coverage(rect: bounds, radius: side * 0.2, bounds: bounds) else { return lensed }
        return lensed.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
    }
}

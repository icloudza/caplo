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
/// 内核用 Core Image 内核语言在运行时编译（与 `CardShape` 同一做法）；编译失败时 `isAvailable` 为假，调用方退回 PNG 素材。
enum LiquidGlass {
    /// 光标样式表里"透明玻璃"的 ID。
    static let styleID = "4-01"

    private static let source = """
    kernel vec4 liquidGlass(sampler src, vec2 center, float radius, float opacity) {
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
        float factor = 0.7 + 1.2 * bend;
        vec2 base = center + d * factor;
        vec2 step = dir * (0.02 * radius * bend);
        vec4 mid = (sample(src, samplerTransform(src, base - 2.0 * step)) + sample(src, samplerTransform(src, base - step))
                    + sample(src, samplerTransform(src, base)) + sample(src, samplerTransform(src, base + step))
                    + sample(src, samplerTransform(src, base + 2.0 * step))) / 5.0;
        vec2 spread = dir * (0.06 * radius * bend);
        float red = sample(src, samplerTransform(src, base + spread)).r;
        float blue = sample(src, samplerTransform(src, base - spread)).b;
        vec4 glass = vec4(mix(mid.r, red, 0.9), mid.g, mix(mid.b, blue, 0.9), mid.a);
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

    private static let kernel: CIKernel? = (CIKernel.makeKernels(source: source) as? [CIKernel])?.first { $0.name == "liquidGlass" }

    static var isAvailable: Bool { kernel != nil }

    /// 在 `image` 上 `center` 处放一枚半径 `radius`（像素）的玻璃透镜，`opacity` 用于光标淡入淡出。
    /// 只在透镜外接方框（含投影）里求值，再盖回原图：整帧不多走一遍。
    static func lens(over image: CIImage, center: CGPoint, radius: CGFloat, opacity: Double) -> CIImage {
        guard let kernel, radius > 1, opacity > 0.001 else { return image }
        // 投影圆心下移 0.1 倍半径、淡到 1.42 倍半径为止，方框取 1.55 倍才不会在底边切出硬边。
        let reach = radius * 1.55
        let extent = CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2).integral
        // 采样落在画面外时取边缘像素，透镜贴着画面边缘时不会把透明区折射进来。
        // 斜面最外缘从约 1.9 倍半径处取样，加上径向平均与色散向外最多偏约 1.0 倍半径，取样范围外扩 1.05 倍半径。
        let source = image.extent.isInfinite ? image : image.clampedToExtent()
        guard let layer = kernel.apply(extent: extent, roiCallback: { _, rect in rect.insetBy(dx: -radius * 1.05, dy: -radius * 1.05) },
                                       arguments: [source, CIVector(x: center.x, y: center.y), radius, opacity]) else { return image }
        return layer.composited(over: image)
    }

    /// 样式格里的预览：几行浅灰"文字条"上放一枚透镜，看得出折射把横线弯过去的样子。
    static func preview(size: CGFloat) -> CIImage {
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
        let lensed = lens(over: canvas, center: CGPoint(x: side * 0.5, y: side * 0.5), radius: side * 0.34, opacity: 1).cropped(to: bounds)
        // 底板切成圆角，放进样式格里像一小块屏幕，而不是一块硬边方片。
        guard let mask = CardShape.coverage(rect: bounds, radius: side * 0.2, bounds: bounds) else { return lensed }
        return lensed.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
    }
}

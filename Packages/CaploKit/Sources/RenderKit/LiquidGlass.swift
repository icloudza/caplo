import CoreGraphics
import CoreImage

/// "透明玻璃"光标的 Liquid Glass 透镜：不再贴一张静态 PNG（静态图只能画出一个灰圈，透不出底下的画面），
/// 而是对光标底下的录屏实时做一次光学处理，预览与导出共用：
///
/// - **折射**：中心约放大 7%；越靠边缘越把圈外的画面收进来（凸透镜边缘的折射），文字和线条在圈边弯过去；
///   边缘环带被压缩，沿径向取三点平均，不然细字在那里会闪成一圈彩色噪点；
/// - **色散**：只在边缘环带里把红、蓝通道沿径向错开一点，出现极细的彩边；
/// - **光**：边缘一圈菲涅耳亮环，左上一道主高光、右下一道弱反光；背光一侧边缘略压暗，白底上也看得出轮廓；
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
        vec2 sd = p - (center + vec2(0.0, -0.06 * radius));
        float shadowAlpha = 0.24 * (1.0 - smoothstep(0.9, 1.34, length(sd) / radius));
        vec4 shadow = vec4(0.0, 0.0, 0.0, shadowAlpha);
        float coverage = 1.0 - smoothstep(radius - 0.75, radius + 0.75, r);
        if (coverage <= 0.0) { return shadow * opacity; }
        float rim = smoothstep(0.55, 1.0, t);
        float factor = 0.93 + 0.30 * rim * rim;
        vec2 base = center + d * factor;
        vec2 step = dir * (0.7 * rim);
        vec4 mid = (sample(src, samplerTransform(src, base - step)) + sample(src, samplerTransform(src, base))
                    + sample(src, samplerTransform(src, base + step))) / 3.0;
        vec2 spread = dir * (0.02 * radius * rim * rim);
        float red = sample(src, samplerTransform(src, base + spread)).r;
        float blue = sample(src, samplerTransform(src, base - spread)).b;
        vec4 glass = vec4(mix(mid.r, red, 0.7), mid.g, mix(mid.b, blue, 0.7), mid.a);
        glass.rgb = glass.rgb * 1.02 + vec3(0.02, 0.02, 0.02) * glass.a;
        vec2 light = normalize(vec2(-0.55, 0.83));
        float facing = dot(dir, light);
        float edge = smoothstep(0.86, 1.0, t);
        glass.rgb = glass.rgb * (1.0 - 0.16 * edge * (0.5 - 0.5 * facing));
        float fresnel = smoothstep(0.8, 1.0, t) * 0.16;
        float spec = pow(max(facing, 0.0), 5.0) * smoothstep(0.76, 0.97, t) * 0.6;
        float back = pow(max(-facing, 0.0), 6.0) * smoothstep(0.86, 0.98, t) * 0.22;
        float glow = fresnel + spec + back;
        glass.rgb = min(glass.rgb + vec3(glow, glow, glow) * glass.a, vec3(glass.a, glass.a, glass.a));
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
        let reach = radius * 1.4
        let extent = CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2).integral
        // 采样落在画面外时取边缘像素，透镜贴着画面边缘时不会把透明区折射进来。
        let source = image.extent.isInfinite ? image : image.clampedToExtent()
        guard let layer = kernel.apply(extent: extent, roiCallback: { _, rect in rect.insetBy(dx: -radius * 0.7, dy: -radius * 0.7) },
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

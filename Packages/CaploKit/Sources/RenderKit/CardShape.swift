import CoreImage
import CoreGraphics

/// 卡片形状的解析几何：圆角（可切超椭圆 squircle）、抗锯齿覆盖率与柔和阴影都由同一个带符号距离场（SDF）算出，
/// 一个像素一次求值，没有额外的模糊 pass；半分辨率预览与 4K 导出按同一公式得到同一形状。
///
/// 内核用 Core Image 内核语言在运行时编译，不依赖构建期的 Metal 工具链；编译失败时 `isAvailable` 为假，
/// 调用方回退到 `CIRoundedRectangleGenerator` + 高斯模糊的老路径。
public enum CardShape {
    /// 圆角形状指数：2 是普通圆角，4 是 macOS 风格的超椭圆（squircle）。目前保持 2 以不改变现有观感。
    public static let cornerPower = 2.0

    private static let source = """
    float cardDistance(vec2 p, vec2 center, vec2 halfSize, float r, float power) {
        vec2 q = abs(p - center) - (halfSize - vec2(r, r));
        vec2 qc = max(q, vec2(0.0, 0.0));
        float n;
        if (power > 2.5) { n = pow(pow(qc.x, power) + pow(qc.y, power), 1.0 / power); } else { n = length(qc); }
        return n + min(max(q.x, q.y), 0.0) - r;
    }
    kernel vec4 cardCoverage(vec2 center, vec2 halfSize, float radius, float power) {
        vec2 p = destCoord();
        float c = 1.0 - smoothstep(-0.5, 0.5, cardDistance(p + vec2(-0.25, -0.25), center, halfSize, radius, power));
        c += 1.0 - smoothstep(-0.5, 0.5, cardDistance(p + vec2(0.25, -0.25), center, halfSize, radius, power));
        c += 1.0 - smoothstep(-0.5, 0.5, cardDistance(p + vec2(-0.25, 0.25), center, halfSize, radius, power));
        c += 1.0 - smoothstep(-0.5, 0.5, cardDistance(p + vec2(0.25, 0.25), center, halfSize, radius, power));
        c *= 0.25;
        return vec4(c, c, c, c);
    }
    kernel vec4 cardShadow(vec2 center, vec2 halfSize, float radius, float power, float blur, float opacity) {
        float d = cardDistance(destCoord(), center, halfSize, radius, power);
        float a = opacity * (1.0 - smoothstep(-blur, blur, d));
        return vec4(0.0, 0.0, 0.0, a);
    }
    """

    private static let kernels: [CIColorKernel] = CIColorKernel.makeKernels(source: source) as? [CIColorKernel] ?? []
    private static var coverageKernel: CIColorKernel? { kernels.first { $0.name == "cardCoverage" } }
    private static var shadowKernel: CIColorKernel? { kernels.first { $0.name == "cardShadow" } }

    /// 内核是否编译成功；假时调用方走老路径。
    public static var isAvailable: Bool { coverageKernel != nil && shadowKernel != nil }

    /// 圆角矩形的抗锯齿覆盖率（白色、alpha 即覆盖率），4 次 ±0.25 像素亚采样。
    public static func coverage(rect: CGRect, radius: Double, bounds: CGRect, power: Double = cornerPower) -> CIImage? {
        guard let kernel = coverageKernel, rect.width > 0, rect.height > 0 else { return nil }
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        let arguments: [Any] = [CIVector(x: rect.midX, y: rect.midY), CIVector(x: rect.width / 2, y: rect.height / 2), r, power]
        return kernel.apply(extent: bounds, arguments: arguments)?.cropped(to: bounds)
    }

    /// 柔和阴影：黑色，alpha 从形状边缘向外按 `blur` 像素平滑衰减（边缘处为不透明度的一半，与高斯模糊的观感一致），
    /// `offset` 为向下的偏移（像素）。只在形状外扩 `blur` 的范围内求值。
    public static func shadow(rect: CGRect, radius: Double, blur: Double, offset: Double, opacity: Double, bounds: CGRect, power: Double = cornerPower) -> CIImage? {
        guard let kernel = shadowKernel, rect.width > 0, rect.height > 0, opacity > 0 else { return nil }
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        let shifted = rect.offsetBy(dx: 0, dy: -offset)
        let softness = max(0.5, blur)
        let extent = shifted.insetBy(dx: -softness - 1, dy: -softness - 1).intersection(bounds)
        guard !extent.isNull, !extent.isEmpty else { return nil }
        let arguments: [Any] = [CIVector(x: shifted.midX, y: shifted.midY), CIVector(x: shifted.width / 2, y: shifted.height / 2), r, power, softness, min(1, max(0, opacity))]
        return kernel.apply(extent: extent, arguments: arguments)?.cropped(to: bounds)
    }
}

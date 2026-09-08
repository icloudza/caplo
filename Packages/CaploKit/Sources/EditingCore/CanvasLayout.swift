import Foundation
import CoreGraphics

/// 成片比例。名称即持久化值，新增项只能追加；`common` 是面板 chips 的顺序，其余比例经平台下拉进入。
public enum CanvasRatio: String, CaseIterable, Codable, Sendable {
    case widescreen = "16:9"
    case standard = "4:3"
    case square = "1:1"
    case portrait = "9:16"
    case tall = "3:4"
    case feed = "4:5"
    case channels = "6:7"
    case ultrawide = "21:9"

    public var value: Double {
        switch self {
        case .widescreen: 16.0 / 9
        case .standard: 4.0 / 3
        case .square: 1
        case .portrait: 9.0 / 16
        case .tall: 3.0 / 4
        case .feed: 4.0 / 5
        case .channels: 6.0 / 7
        case .ultrawide: 21.0 / 9
        }
    }

    /// 横 / 竖 / 方，平台下拉按此分组，与地区无关。
    public enum Orientation: String, CaseIterable, Sendable {
        case landscape = "横屏"
        case portrait = "竖屏"
        case square = "方形"
    }
    public var orientation: Orientation { value > 1 ? .landscape : value < 1 ? .portrait : .square }

    /// 面板里直接可点的常用比例；4:5、6:7 只从平台下拉进入。
    public static let common: [CanvasRatio] = [.widescreen, .portrait, .standard, .tall, .square, .ultrawide]

    /// 输出尺寸：短边固定（1080p 为 1080，4K 为 2160），长边按比例伸展并取偶数；面板提示与导出共用同一算法。
    public func outputSize(shortEdge: Int) -> (width: Int, height: Int) {
        let base = Double(shortEdge)
        let width = value >= 1 ? base * value : base
        let height = value >= 1 ? base : base / value
        return (Int(width.rounded()) / 2 * 2, Int(height.rounded()) / 2 * 2)
    }
}

/// 背景色板：渐变由两个端点色构成，纯色两端相同。名称即持久化值，新增项只能追加。
public enum CanvasBackground: String, CaseIterable, Codable, Sendable {
    case iris = "鸢尾"
    case ocean = "海盐"
    case peach = "蜜桃"
    case graphite = "石墨"
    case dusk = "薄暮"
    case forest = "森林"
    case amber = "琥珀"
    case midnight = "极夜"
    case solidWhite = "纯白"
    case solidLightGray = "浅灰"
    case solidDarkGray = "深灰"
    case solidBlack = "纯黑"
    case solidViolet = "紫"
    case solidIndigo = "靛蓝"
    case solidTeal = "青"
    case solidCoral = "珊瑚"

    public var isSolid: Bool { rawValue.hasPrefix("纯") || [.solidLightGray, .solidDarkGray, .solidViolet, .solidIndigo, .solidTeal, .solidCoral].contains(self) }
    public static var gradients: [CanvasBackground] { allCases.filter { !$0.isSolid } }
    public static var solids: [CanvasBackground] { allCases.filter(\.isSolid) }

    /// sRGB 端点色；渲染器与色板共用同一张表，保证预览、导出与面板一致。
    public var colors: (start: (red: Double, green: Double, blue: Double), end: (red: Double, green: Double, blue: Double)) {
        switch self {
        case .iris: ((0.38, 0.36, 0.85), (0.85, 0.70, 0.95))
        case .ocean: ((0.12, 0.48, 0.65), (0.64, 0.90, 0.85))
        case .peach: ((0.95, 0.49, 0.42), (1, 0.85, 0.64))
        case .graphite: ((0.12, 0.14, 0.18), (0.35, 0.38, 0.44))
        case .dusk: ((0.17, 0.12, 0.35), (0.86, 0.45, 0.48))
        case .forest: ((0.09, 0.32, 0.26), (0.55, 0.80, 0.55))
        case .amber: ((0.82, 0.42, 0.10), (1.0, 0.82, 0.35))
        case .midnight: ((0.05, 0.07, 0.15), (0.14, 0.25, 0.48))
        case .solidWhite: ((1, 1, 1), (1, 1, 1))
        case .solidLightGray: ((0.90, 0.90, 0.92), (0.90, 0.90, 0.92))
        case .solidDarkGray: ((0.20, 0.20, 0.23), (0.20, 0.20, 0.23))
        case .solidBlack: ((0.02, 0.02, 0.03), (0.02, 0.02, 0.03))
        case .solidViolet: ((0.42, 0.39, 0.94), (0.42, 0.39, 0.94))
        case .solidIndigo: ((0.18, 0.22, 0.55), (0.18, 0.22, 0.55))
        case .solidTeal: ((0.10, 0.60, 0.62), (0.10, 0.60, 0.62))
        case .solidCoral: ((0.96, 0.45, 0.40), (0.96, 0.45, 0.40))
        }
    }
}

/// 归一化裁切矩形，原点在源画面左上角；聚焦与指针坐标随之重新映射。
public struct CropRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public static let full = CropRect(x: 0, y: 0, width: 1, height: 1)
    public static let minimumSide = 0.1

    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width >= Self.minimumSide && height >= Self.minimumSide
            && x + width <= 1.000001 && y + height <= 1.000001
    }
    public var isFull: Bool { abs(x) < 0.0001 && abs(y) < 0.0001 && abs(width - 1) < 0.0001 && abs(height - 1) < 0.0001 }

    /// 以给定宽高比在源画面中央取最大矩形；`sourceAspect` 为源画面宽高比。
    public static func centered(aspect: Double, sourceAspect: Double) -> CropRect {
        guard aspect.isFinite, aspect > 0, sourceAspect.isFinite, sourceAspect > 0 else { return .full }
        if aspect >= sourceAspect {
            let height = sourceAspect / aspect
            return CropRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        }
        let width = aspect / sourceAspect
        return CropRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
    }

    /// 把源画面归一化坐标换算到裁切后的归一化坐标。
    public func remap(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - x) / max(0.0001, width), y: (point.y - y) / max(0.0001, height))
    }
}

public struct CanvasLayout: Equatable, Codable, Sendable {
    public var ratio: CanvasRatio = .widescreen
    public var background: CanvasBackground = .iris
    /// 工程包内的自定义背景图相对路径（`Backgrounds/…`）；存在时覆盖色板背景。
    public var backgroundImage: String?
    public var padding: Double = 40
    public var cornerRadius: Double = 12
    public var shadow: Bool = true
    /// 阴影参数以 960 点宽画布为参考：不透明度 0…1，柔和度（模糊 σ）与向下距离单位为点。
    public var shadowOpacity: Double = Self.defaultShadowOpacity
    public var shadowBlur: Double = Self.defaultShadowBlur
    public var shadowOffset: Double = Self.defaultShadowOffset
    /// 为空表示不裁切。
    public var crop: CropRect?
    /// 固定聚焦区域：开则镜头推近只放大录屏框里的内容，留白 / 背景 / 圆角框不动；关（新工程默认）则整个画面一起推近。
    /// 旧工程没有这个字段时按开读，保持它们原来的效果。
    public var fixedFocusFrame = false
    /// 自定义布局：录屏在留白之内再缩小的比例（0.3…1）与在剩余空间里的位置（−1…1，0 居中，Y 向下为正）。
    /// 只对叠放的人像布局生效，卡片布局的录屏位置由布局决定。
    public var screenScale = 1.0
    public var screenOffsetX = 0.0
    public var screenOffsetY = 0.0

    public static let defaultShadowOpacity = 0.3
    public static let defaultShadowBlur = 12.0
    public static let defaultShadowOffset = 8.0

    public init() {}

    public var effectiveCrop: CropRect? {
        guard let crop, crop.isValid, !crop.isFull else { return nil }
        return crop
    }

    private enum CodingKeys: String, CodingKey {
        case ratio, background, backgroundImage, padding, cornerRadius, shadow, shadowOpacity, shadowBlur, shadowOffset, crop, fixedFocusFrame, screenScale, screenOffsetX, screenOffsetY
    }

    /// 旧工程没有阴影参数，按默认值解码，像素与之前完全一致。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ratio = try container.decode(CanvasRatio.self, forKey: .ratio)
        background = try container.decode(CanvasBackground.self, forKey: .background)
        backgroundImage = try container.decodeIfPresent(String.self, forKey: .backgroundImage)
        padding = try container.decode(Double.self, forKey: .padding)
        cornerRadius = try container.decode(Double.self, forKey: .cornerRadius)
        shadow = try container.decode(Bool.self, forKey: .shadow)
        shadowOpacity = try container.decodeIfPresent(Double.self, forKey: .shadowOpacity) ?? Self.defaultShadowOpacity
        shadowBlur = try container.decodeIfPresent(Double.self, forKey: .shadowBlur) ?? Self.defaultShadowBlur
        shadowOffset = try container.decodeIfPresent(Double.self, forKey: .shadowOffset) ?? Self.defaultShadowOffset
        crop = try container.decodeIfPresent(CropRect.self, forKey: .crop)
        fixedFocusFrame = try container.decodeIfPresent(Bool.self, forKey: .fixedFocusFrame) ?? true
        screenScale = try container.decodeIfPresent(Double.self, forKey: .screenScale) ?? 1
        screenOffsetX = try container.decodeIfPresent(Double.self, forKey: .screenOffsetX) ?? 0
        screenOffsetY = try container.decodeIfPresent(Double.self, forKey: .screenOffsetY) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ratio, forKey: .ratio)
        try container.encode(background, forKey: .background)
        try container.encodeIfPresent(backgroundImage, forKey: .backgroundImage)
        try container.encode(padding, forKey: .padding)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(shadow, forKey: .shadow)
        try container.encode(shadowOpacity, forKey: .shadowOpacity)
        try container.encode(shadowBlur, forKey: .shadowBlur)
        try container.encode(shadowOffset, forKey: .shadowOffset)
        try container.encodeIfPresent(crop, forKey: .crop)
        try container.encode(fixedFocusFrame, forKey: .fixedFocusFrame)
        try container.encode(screenScale, forKey: .screenScale)
        try container.encode(screenOffsetX, forKey: .screenOffsetX)
        try container.encode(screenOffsetY, forKey: .screenOffsetY)
    }
}

/// 供预览及后续导出共用的等比适配计算，保留完整内容，不进行裁切。
public enum LayoutGeometry {
    public static func fittedSize(content: CGSize, inside bounds: CGSize, padding: Double) -> CGSize {
        // 阻止无效尺寸传播到渲染层；留白耗尽可用空间时，结果自然收敛为零尺寸。
        guard content.width.isFinite, content.height.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              content.width > 0, content.height > 0,
              bounds.width > 0, bounds.height > 0, padding.isFinite else { return .zero }
        let inset = max(0, padding)
        let width = max(0, bounds.width - inset * 2)
        let height = max(0, bounds.height - inset * 2)
        let scale = min(width / content.width, height / content.height)
        return CGSize(width: content.width * scale, height: content.height * scale)
    }
}

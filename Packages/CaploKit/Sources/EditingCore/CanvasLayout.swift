import Foundation
import CoreGraphics

/// 成片比例。名称即持久化值，新增项只能追加；`common` 是面板 chips 的顺序，其余比例经平台下拉进入。
/// `original`（原始）跟着录制画面走（裁剪过就是裁剪后的比例），数值存在 `CanvasLayout.originalAspect`，
/// 所以取画布比例一律用 `CanvasLayout.aspect`，不要直接读 `value`。新工程默认原始：边距为 0 时就是原片，不露背景。
public enum CanvasRatio: String, CaseIterable, Codable, Sendable {
    case original = "原始"
    case widescreen = "16:9"
    case standard = "4:3"
    case square = "1:1"
    case portrait = "9:16"
    case tall = "3:4"
    case feed = "4:5"
    case channels = "6:7"
    case ultrawide = "21:9"

    /// 固定比例的数值；原始没有固定值（这里回 16:9 只是兜底，真正的值见 `CanvasLayout.aspect`）。
    public var value: Double {
        switch self {
        case .original, .widescreen: 16.0 / 9
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

    /// 面板里直接可点的常用比例（一排只放得下六个）；4:5、6:7、21:9 只从平台下拉进入。
    public static let common: [CanvasRatio] = [.original, .widescreen, .portrait, .standard, .tall, .square]

    /// 输出尺寸：短边固定（1080p 为 1080，4K 为 2160），长边按比例伸展并取偶数；面板提示与导出共用同一算法。
    public static func outputSize(aspect value: Double, shortEdge: Int) -> (width: Int, height: Int) {
        let base = Double(shortEdge)
        let width = value >= 1 ? base * value : base
        let height = value >= 1 ? base : base / value
        return (Int(width.rounded()) / 2 * 2, Int(height.rounded()) / 2 * 2)
    }
}

/// 背景：预设名，或自定义色。名称即持久化值，**预设只能追加、不能改名**——
/// 认不出的名字退回默认档（见 `CanvasLayout` 的解码），删一档就是让存过它的工程悄悄换个背景。
/// 2026-09-11 渐变的色标整体换成 Cap（CapSoftware/Cap）编辑器那套预设，去掉首尾两档、其余按它的顺序排。
/// 自定义色存成 `#RRGGBB`（纯色）或 `#RRGGBB-#RRGGBB`（渐变），面板最后那格「自定义」写的就是它。
public struct CanvasBackground: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let shoal = CanvasBackground(rawValue: "浅滩")
    public static let neon = CanvasBackground(rawValue: "霓虹")
    public static let iris = CanvasBackground(rawValue: "鸢尾")
    public static let dusk = CanvasBackground(rawValue: "薄暮")
    public static let plum = CanvasBackground(rawValue: "紫焰")
    public static let spark = CanvasBackground(rawValue: "火花")
    public static let lava = CanvasBackground(rawValue: "熔岩")
    public static let cyber = CanvasBackground(rawValue: "赛博")
    public static let jade = CanvasBackground(rawValue: "翡翠")
    public static let peach = CanvasBackground(rawValue: "蜜桃")
    public static let graphite = CanvasBackground(rawValue: "石墨")
    public static let ocean = CanvasBackground(rawValue: "海盐")
    public static let midnight = CanvasBackground(rawValue: "极夜")
    public static let amber = CanvasBackground(rawValue: "琥珀")
    public static let volt = CanvasBackground(rawValue: "电光")
    public static let sunrise = CanvasBackground(rawValue: "日出")
    /// 只为旧工程保留：面板上已经撤掉，存过它的工程照旧画得出来。
    public static let forest = CanvasBackground(rawValue: "森林")
    public static let solidWhite = CanvasBackground(rawValue: "纯白")
    public static let solidLightGray = CanvasBackground(rawValue: "浅灰")
    public static let solidDarkGray = CanvasBackground(rawValue: "深灰")
    public static let solidBlack = CanvasBackground(rawValue: "纯黑")
    public static let solidViolet = CanvasBackground(rawValue: "紫")
    public static let solidIndigo = CanvasBackground(rawValue: "靛蓝")
    public static let solidTeal = CanvasBackground(rawValue: "青")
    public static let solidCoral = CanvasBackground(rawValue: "珊瑚")

    /// 面板上的渐变档与顺序。
    public static let gradients: [CanvasBackground] = [.shoal, .neon, .iris, .dusk, .plum, .spark, .lava, .cyber, .jade, .peach, .graphite, .ocean, .midnight, .amber, .volt, .sunrise]
    /// 面板上的纯色档。
    public static let solids: [CanvasBackground] = [.solidWhite, .solidLightGray, .solidDarkGray, .solidBlack, .solidViolet, .solidIndigo, .solidTeal, .solidCoral]

    /// 自定义色：两端相同就是纯色，不同就是渐变。
    public init(start: (red: Double, green: Double, blue: Double), end: (red: Double, green: Double, blue: Double)) {
        let from = Self.hex(start), to = Self.hex(end)
        rawValue = from == to ? from : from + "-" + to
    }

    /// 用户自己调的颜色，不是预设档。
    public var isCustom: Bool { Self.parse(rawValue) != nil }
    /// 两端同色即纯色；预设的纯色档与自定义单色都算。
    public var isSolid: Bool { let value = colors; return value.start == value.end }

    /// sRGB 端点色；渲染器与色板共用同一张表，保证预览、导出与面板一致。
    public var colors: (start: (red: Double, green: Double, blue: Double), end: (red: Double, green: Double, blue: Double)) {
        if let custom = Self.parse(rawValue) { return custom }
        switch rawValue {
        case "浅滩": return ((0.133, 0.757, 0.765), (0.992, 0.733, 0.176))
        case "霓虹": return ((0.114, 0.992, 0.984), (0.765, 0.114, 0.992))
        case "鸢尾": return ((0.271, 0.408, 0.863), (0.690, 0.416, 0.702))
        case "薄暮": return ((0.416, 0.510, 0.984), (0.988, 0.361, 0.490))
        case "紫焰": return ((0.514, 0.227, 0.706), (0.992, 0.114, 0.114))
        case "火花": return ((0.976, 0.831, 0.137), (1.000, 0.306, 0.314))
        case "熔岩": return ((1.000, 0.369, 0.000), (1.000, 0.165, 0.408))
        case "赛博": return ((1.000, 0.000, 0.588), (0.000, 0.800, 1.000))
        case "翡翠": return ((0.000, 0.949, 0.376), (0.020, 0.459, 0.902))
        case "蜜桃": return ((0.933, 0.804, 0.639), (0.937, 0.384, 0.624))
        case "石墨": return ((0.173, 0.243, 0.314), (0.204, 0.596, 0.859))
        case "海盐": return ((0.659, 0.937, 1.000), (0.933, 0.804, 0.639))
        case "极夜": return ((0.290, 0.000, 0.878), (0.561, 0.000, 1.000))
        case "琥珀": return ((0.988, 0.290, 0.102), (0.969, 0.718, 0.200))
        case "电光": return ((0.000, 1.000, 1.000), (1.000, 0.078, 0.576))
        case "日出": return ((1.000, 0.498, 0.000), (1.000, 1.000, 0.000))
        case "森林": return ((0.059, 0.204, 0.263), (0.204, 0.910, 0.620))
        case "纯白": return ((1.000, 1.000, 1.000), (1.000, 1.000, 1.000))
        case "浅灰": return ((0.902, 0.902, 0.922), (0.902, 0.902, 0.922))
        case "深灰": return ((0.200, 0.200, 0.231), (0.200, 0.200, 0.231))
        case "纯黑": return ((0.020, 0.020, 0.031), (0.020, 0.020, 0.031))
        case "紫": return ((0.420, 0.388, 0.941), (0.420, 0.388, 0.941))
        case "靛蓝": return ((0.180, 0.220, 0.549), (0.180, 0.220, 0.549))
        case "青": return ((0.102, 0.600, 0.620), (0.102, 0.600, 0.620))
        case "珊瑚": return ((0.961, 0.451, 0.400), (0.961, 0.451, 0.400))
        // 认不出的名字按默认档画，绝不返回一片黑让用户以为画面坏了。
        default: return Self.iris.colors
        }
    }

    /// 工程文件里存的一直是一个字符串，换成结构体之后也不能变。
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func hex(_ color: (red: Double, green: Double, blue: Double)) -> String {
        func byte(_ value: Double) -> Int { Int((min(1, max(0, value.isFinite ? value : 0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
    }
    private static func component(_ text: Substring) -> (red: Double, green: Double, blue: Double)? {
        guard text.count == 7, text.hasPrefix("#"), let number = Int(text.dropFirst(), radix: 16) else { return nil }
        return (Double((number >> 16) & 0xFF) / 255, Double((number >> 8) & 0xFF) / 255, Double(number & 0xFF) / 255)
    }
    private static func parse(_ value: String) -> (start: (red: Double, green: Double, blue: Double), end: (red: Double, green: Double, blue: Double))? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 1, let single = component(parts[0]) { return (single, single) }
        guard parts.count == 2, let from = component(parts[0]), let to = component(parts[1]) else { return nil }
        return (from, to)
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
    /// `remap` 的逆：裁切区归一化坐标换回整幅画面归一化坐标。
    public func restore(_ point: CGPoint) -> CGPoint {
        CGPoint(x: x + point.x * width, y: y + point.y * height)
    }
}

public struct CanvasLayout: Equatable, Codable, Sendable {
    public var ratio: CanvasRatio = .original
    /// 录制画面（裁剪后）的宽高比，"原始"比例用它。打开工程和每次编辑时按录制尺寸与裁剪重算（`syncOriginalAspect`）。
    public var originalAspect: Double = 16.0 / 9
    public var background: CanvasBackground = .iris
    /// 工程包内的自定义背景图相对路径（`Backgrounds/…`）；存在时覆盖色板背景。
    public var backgroundImage: String?
    public var padding: Double = 0
    public var cornerRadius: Double = 12
    /// 背景图的模糊程度 0…100（相对 960 点宽等比换算）。只对图片有意义：渐变糊了还是同一片渐变。
    public var backgroundBlur: Double = 0
    public var shadow: Bool = false
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

    /// 画布背景整体偏亮吗。只用于把旧工程里的「自动」文字色落成固定色——
    /// 它当年就是按这个判的，照原样落一遍，老工程的画面才不会变。
    public var isLightBackground: Bool {
        guard backgroundImage == nil else { return false }
        let colors = background.colors
        func luma(_ color: (red: Double, green: Double, blue: Double)) -> Double {
            0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
        }
        return (luma(colors.start) + luma(colors.end)) / 2 > 0.62
    }

    public var effectiveCrop: CropRect? {
        guard let crop, crop.isValid, !crop.isFull else { return nil }
        return crop
    }

    /// 画布实际的宽高比：原始取录制画面，其余取固定比例。画布、预览、导出尺寸都读它。
    public var aspect: Double { ratio == .original ? originalAspect : ratio.value }
    public func outputSize(shortEdge: Int) -> (width: Int, height: Int) { CanvasRatio.outputSize(aspect: aspect, shortEdge: shortEdge) }

    /// 按录制像素尺寸与当前裁剪重算原始比例；拿不到尺寸时不动。夹在 1:5…5:1，异常尺寸不至于把画布挤没。
    public mutating func syncOriginalAspect(capture: CGSize?) {
        guard let capture, capture.width > 0, capture.height > 0, capture.width.isFinite, capture.height.isFinite else { return }
        let crop = effectiveCrop
        let width = Double(capture.width) * (crop?.width ?? 1), height = Double(capture.height) * (crop?.height ?? 1)
        guard width > 0, height > 0 else { return }
        let value = min(5, max(0.2, width / height))
        if abs(value - originalAspect) > 0.000_001 { originalAspect = value }
    }

    private enum CodingKeys: String, CodingKey {
        case ratio, background, backgroundImage, backgroundBlur, padding, cornerRadius, shadow, shadowOpacity, shadowBlur, shadowOffset, crop, fixedFocusFrame, screenScale, screenOffsetX, screenOffsetY
        case originalAspect
    }

    /// 旧工程没有阴影参数，按默认值解码，像素与之前完全一致。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ratio = try container.decode(CanvasRatio.self, forKey: .ratio)
        // 认不出的背景名（改过名、或工程来自更新的版本）退回默认那一档，不能让一个名字把整份工程判死。
        background = (try? container.decode(CanvasBackground.self, forKey: .background)) ?? .iris
        backgroundImage = try container.decodeIfPresent(String.self, forKey: .backgroundImage)
        padding = try container.decode(Double.self, forKey: .padding)
        cornerRadius = try container.decode(Double.self, forKey: .cornerRadius)
        backgroundBlur = try container.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? 0
        shadow = try container.decode(Bool.self, forKey: .shadow)
        shadowOpacity = try container.decodeIfPresent(Double.self, forKey: .shadowOpacity) ?? Self.defaultShadowOpacity
        shadowBlur = try container.decodeIfPresent(Double.self, forKey: .shadowBlur) ?? Self.defaultShadowBlur
        shadowOffset = try container.decodeIfPresent(Double.self, forKey: .shadowOffset) ?? Self.defaultShadowOffset
        crop = try container.decodeIfPresent(CropRect.self, forKey: .crop)
        fixedFocusFrame = try container.decodeIfPresent(Bool.self, forKey: .fixedFocusFrame) ?? true
        screenScale = try container.decodeIfPresent(Double.self, forKey: .screenScale) ?? 1
        screenOffsetX = try container.decodeIfPresent(Double.self, forKey: .screenOffsetX) ?? 0
        screenOffsetY = try container.decodeIfPresent(Double.self, forKey: .screenOffsetY) ?? 0
        originalAspect = try container.decodeIfPresent(Double.self, forKey: .originalAspect) ?? 16.0 / 9
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ratio, forKey: .ratio)
        try container.encode(background, forKey: .background)
        try container.encodeIfPresent(backgroundImage, forKey: .backgroundImage)
        try container.encode(padding, forKey: .padding)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(backgroundBlur, forKey: .backgroundBlur)
        try container.encode(shadow, forKey: .shadow)
        try container.encode(shadowOpacity, forKey: .shadowOpacity)
        try container.encode(shadowBlur, forKey: .shadowBlur)
        try container.encode(shadowOffset, forKey: .shadowOffset)
        try container.encodeIfPresent(crop, forKey: .crop)
        try container.encode(fixedFocusFrame, forKey: .fixedFocusFrame)
        try container.encode(screenScale, forKey: .screenScale)
        try container.encode(screenOffsetX, forKey: .screenOffsetX)
        try container.encode(screenOffsetY, forKey: .screenOffsetY)
        try container.encode(originalAspect, forKey: .originalAspect)
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

extension VideoEdit {
    /// 把聚焦坐标换算到裁切区域，得到与渲染端完全一致的一份副本。
    ///
    /// 裁切之后录屏画面只剩中间一块，聚焦的归一化坐标必须跟着改口径，
    /// 否则相机会对着一个不存在的位置推近。渲染端一直这么做（见 `SceneRenderer.frame`）；
    /// 画布上的编辑框也必须用同一份，不然两边的相机不是同一个点，框就和画面分家。
    public func cropResolved() -> VideoEdit {
        guard let crop = layout.effectiveCrop, !crop.isFull else { return self }
        var result = self
        result.focuses = focuses.map { focus in
            var mapped = focus
            let point = crop.remap(CGPoint(x: focus.x, y: focus.y))
            mapped.x = min(1, max(0, point.x)); mapped.y = min(1, max(0, point.y))
            mapped.path = focus.path?.map { frame in
                var moved = frame
                let point = crop.remap(CGPoint(x: frame.x, y: frame.y))
                moved.x = min(1, max(0, point.x)); moved.y = min(1, max(0, point.y))
                return moved
            }
            return mapped
        }
        return result
    }
}

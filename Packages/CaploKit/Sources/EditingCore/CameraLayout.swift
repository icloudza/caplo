import Foundation
import CoreGraphics

/// 人像位置相对可移动区域归一化，左上为零；更换画布比例后仍保留边距且不会出界。
/// 镜头聚焦只变换屏幕，人像作为最后一层独立合成。
/// 这是编辑器里成片人像的唯一布局来源，与录制时屏幕上那个可拖动的画中画取景窗无关（那个不保存位置）。
public struct CameraLayout: Codable, Equatable, Sendable {
    public enum Shape: String, Codable, CaseIterable, Sendable { case circle, roundedRectangle }
    /// 叠放：人像按归一化位置浮在录屏之上；侧边：小竖卡片贴一侧、垂直居中、三分之二压在录屏边缘上，录屏向另一侧靠；
    /// 在后：大竖卡片贴一侧、垂直居中，垫在录屏后面，录屏向另一侧靠并压住卡片四分之一；
    /// 分屏：竖卡片与录屏并排不重叠、同高，尺寸完全由画布决定（都对应 FocuSee 的布局）。每种都有左右两个方向，“水平翻转”互换。
    /// 人像全屏：人像铺满画布垫底，录屏缩成小窗（位置与大小由画面布局的 screenScale / screenOffset 决定）。
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case overlay, sideLeading, sideTrailing, behindLeading, behindTrailing, splitLeading, splitTrailing, cameraFull
        public var leading: Bool { self == .sideLeading || self == .behindLeading || self == .splitLeading }
        public var flipped: Mode {
            switch self {
            case .overlay: .overlay
            case .cameraFull: .cameraFull
            case .sideLeading: .sideTrailing; case .sideTrailing: .sideLeading
            case .behindLeading: .behindTrailing; case .behindTrailing: .behindLeading
            case .splitLeading: .splitTrailing; case .splitTrailing: .splitLeading
            }
        }
    }
    public var enabled = true
    public var mode: Mode = .overlay
    public var shape: Shape = .circle
    /// 叠放时人像直径 / 宽度相对画布短边。
    public var size = 0.24
    /// 卡片高度相对内容区高（卡片宽高 3 : 5）：侧边默认 0.45（0.4…0.8），在后默认 0.9（0.6…1）。
    public var sideHeight = 0.45
    public var x = 1.0
    public var y = 1.0
    public var mirrored = true
    public var shadow = true
    /// 圆角相对短边（0…0.5）：圆形预设是 1 : 1 加 0.5（正圆），拉小就是圆角方块；圆角矩形与卡片默认 0.14。
    public var cornerRadius = 0.5
    /// 叠放圆角矩形的宽高比（宽 / 高，0.25…4），圆形不用；默认 4 : 3，从卡片布局换算成自定义布局时是 3 : 5。
    public var aspect = 4.0 / 3.0
    /// 叠放时人像垫在录屏下面（从“在后”换算成自定义布局时保留层级）。
    public var belowScreen = false
    /// 叠放时随镜头聚焦缩小：推近过程中按同一条包络缩到 `focusedScale` 倍并淡到 85 %，拉远时放回来。
    public var shrinkOnFocus = true
    public var focusedScale = 0.7
    public init() {}

    public var isSide: Bool { mode == .sideLeading || mode == .sideTrailing }
    public var isBehind: Bool { mode == .behindLeading || mode == .behindTrailing }
    public var isSplit: Bool { mode == .splitLeading || mode == .splitTrailing }
    public var isCameraFull: Bool { mode == .cameraFull }

    /// 水平翻转布局（不是镜像画面）：叠放的人像换到对侧，卡片布局左右互换。
    public func flippedHorizontally() -> CameraLayout {
        var copy = self
        if mode == .overlay { copy.x = 1 - x } else { copy.mode = mode.flipped }
        return copy
    }
    /// 侧边、在后、分屏都用竖卡片；分屏的尺寸由画布决定，其余两种“人像高度”滑杆有效。
    public var usesCard: Bool { isSide || isBehind || isSplit }
    /// 在后、分屏、人像全屏以及垫在录屏下面的叠放，人像不带任何聚焦效果（不缩不淡，整体推近时也不动）。
    public var ignoresFocus: Bool { isBehind || isSplit || isCameraFull || (mode == .overlay && belowScreen) }
    /// 人像垫在录屏下面（在后、人像全屏、垫底的叠放）：层级是背景 → 人像 → 录屏阴影 → 录屏。
    public var underScreen: Bool { isBehind || isCameraFull || (mode == .overlay && belowScreen) }
    /// 叠放圆角矩形的宽高比，钳在合法范围。
    public var effectiveAspect: Double { aspect.isFinite ? min(4, max(0.25, aspect)) : 4.0 / 3.0 }

    public var isValid: Bool {
        size.isFinite && (0.12...0.6).contains(size) && x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
            && aspect.isFinite && (0.25...4).contains(aspect)
            && focusedScale.isFinite && (0.4...1).contains(focusedScale) && sideHeight.isFinite && (0.4...1).contains(sideHeight)
            && cornerRadius.isFinite && (0...0.5).contains(cornerRadius)
    }

    /// 聚焦到 `progress`（0…1）时的人像矩形：以停靠点为锚缩放（右下角的人像缩小后仍贴右下角），关掉缩小就是原矩形。
    public func focusedRect(in canvas: CGSize, progress: Double) -> CGRect {
        let base = rect(in: canvas)
        guard shrinkOnFocus, progress > 0 else { return base }
        let factor = 1 - (1 - focusedScale) * min(1, max(0, progress))
        let anchor = CGPoint(x: base.minX + base.width * x, y: base.minY + base.height * (1 - y))
        let width = base.width * factor, height = base.height * factor
        return CGRect(x: anchor.x - width * x, y: anchor.y - height * (1 - y), width: width, height: height)
    }
    /// 聚焦到 `progress` 时的人像不透明度（缩小的同时淡到 85 %）。
    public func focusedOpacity(progress: Double) -> Double {
        shrinkOnFocus && !ignoresFocus ? 1 - 0.15 * min(1, max(0, progress)) : 1
    }

    /// 返回 Core Image 使用的左下角坐标；尺寸以画布短边为基准，横竖画布共用同一含义。
    public func rect(in canvas: CGSize) -> CGRect {
        let edge = min(canvas.width, canvas.height), margin = edge * 0.035
        let width = edge * size, height = shape == .circle ? width : width / effectiveAspect
        return CGRect(x: margin + (canvas.width - 2 * margin - width) * x,
                      y: canvas.height - margin - height - (canvas.height - 2 * margin - height) * y,
                      width: width, height: height)
    }

    /// 侧边几何（左下原点像素坐标）：内容区去掉留白后，卡片高 = 内容区高 × sideHeight、宽高 3 : 5，贴一侧、垂直居中；
    /// 录屏在"卡片三分之一宽之外"的剩余区域等比适配并居中，于是卡片三分之二压在录屏边缘上。`screen` 为零时只算卡片。
    public func sideFrames(canvas: CGSize, padding: Double, screen: CGSize) -> (camera: CGRect, screen: CGRect) {
        let inset = max(0, padding.isFinite ? padding : 0)
        let inner = CGRect(x: inset, y: inset, width: max(0, canvas.width - 2 * inset), height: max(0, canvas.height - 2 * inset))
        let height = inner.height * min(0.8, max(0.4, sideHeight.isFinite ? sideHeight : 0.45))
        let width = min(height * 0.6, inner.width)
        let cameraRect = CGRect(x: mode.leading ? inner.minX : inner.maxX - width, y: inner.midY - height / 2, width: width, height: height)
        let overhang = width / 3
        let remaining = CGRect(x: mode.leading ? inner.minX + overhang : inner.minX, y: inner.minY,
                               width: max(0, inner.width - overhang), height: inner.height)
        let fitted = LayoutGeometry.fittedSize(content: screen, inside: remaining.size, padding: 0)
        let screenRect = CGRect(x: remaining.midX - fitted.width / 2, y: remaining.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
        return (cameraRect, screenRect)
    }

    /// 在后几何：卡片高 = 内容区高 × sideHeight、宽高 3 : 5，贴右、垂直居中；录屏在"卡片左侧四分之一处以左"的区域等比适配并居中，
    /// 于是录屏压住卡片左侧四分之一。卡片在录屏后面，不参与聚焦缩小淡化。
    public func behindFrames(canvas: CGSize, padding: Double, screen: CGSize) -> (camera: CGRect, screen: CGRect) {
        let inset = max(0, padding.isFinite ? padding : 0)
        let inner = CGRect(x: inset, y: inset, width: max(0, canvas.width - 2 * inset), height: max(0, canvas.height - 2 * inset))
        let height = inner.height * min(1, max(0.4, sideHeight.isFinite ? sideHeight : 0.9))
        let width = min(height * 0.6, inner.width)
        let cameraRect = CGRect(x: mode.leading ? inner.minX : inner.maxX - width, y: inner.midY - height / 2, width: width, height: height)
        let available = mode.leading
            ? CGRect(x: cameraRect.maxX - width / 4, y: inner.minY, width: max(0, inner.maxX - (cameraRect.maxX - width / 4)), height: inner.height)
            : CGRect(x: inner.minX, y: inner.minY, width: max(0, cameraRect.minX + width / 4 - inner.minX), height: inner.height)
        let fitted = LayoutGeometry.fittedSize(content: screen, inside: available.size, padding: 0)
        let screenRect = CGRect(x: available.midX - fitted.width / 2, y: available.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
        return (cameraRect, screenRect)
    }

    /// 分屏几何：卡片（宽高 3 : 5）在左、录屏在右并排同高，中间留一个留白（至少 12/960 画布宽）；整行先按内容区高排，
    /// 排不下就整体缩到宽度刚好放下，水平垂直都居中。`screen` 为零时只排卡片。
    public func splitFrames(canvas: CGSize, padding: Double, screen: CGSize) -> (camera: CGRect, screen: CGRect) {
        let inset = max(0, padding.isFinite ? padding : 0)
        let inner = CGRect(x: inset, y: inset, width: max(0, canvas.width - 2 * inset), height: max(0, canvas.height - 2 * inset))
        let gap = max(inset, canvas.width / 960 * 12)
        let cardAspect = 0.6
        let screenAspect = screen.width > 0 && screen.height > 0 ? screen.width / screen.height : 0
        let widthPerHeight = cardAspect + (screenAspect > 0 ? screenAspect : 0)
        let available = screenAspect > 0 ? inner.width - gap : inner.width
        let height = max(0, min(inner.height, widthPerHeight > 0 ? available / widthPerHeight : 0))
        let total = height * widthPerHeight + (screenAspect > 0 ? gap : 0)
        let startX = inner.midX - total / 2, y = inner.midY - height / 2
        let cardWidth = height * cardAspect, screenWidth = height * screenAspect
        let cameraRect = CGRect(x: mode.leading ? startX : startX + total - cardWidth, y: y, width: cardWidth, height: height)
        let screenRect = screenAspect > 0 ? CGRect(x: mode.leading ? cameraRect.maxX + gap : startX, y: y, width: screenWidth, height: height) : .zero
        return (cameraRect, screenRect)
    }

    /// 当前帧的人像矩形：叠放以停靠点为锚随聚焦缩小；侧边卡片以自身中心为锚缩小；在后与分屏的卡片不缩。
    /// `screen` 只有分屏需要（整行尺寸取决于录屏比例）。
    public func portraitRect(canvas: CGSize, padding: Double, screen: CGSize = .zero, progress: Double) -> CGRect {
        if isCameraFull { return CGRect(origin: .zero, size: canvas) }
        if isBehind { return behindFrames(canvas: canvas, padding: padding, screen: .zero).camera }
        if isSplit { return splitFrames(canvas: canvas, padding: padding, screen: screen).camera }
        guard isSide else { return focusedRect(in: canvas, progress: progress) }
        let base = sideFrames(canvas: canvas, padding: padding, screen: .zero).camera
        guard shrinkOnFocus, progress > 0 else { return base }
        let factor = 1 - (1 - focusedScale) * min(1, max(0, progress))
        return CGRect(x: base.midX - base.width * factor / 2, y: base.midY - base.height * factor / 2, width: base.width * factor, height: base.height * factor)
    }

    // 旧工程没有 mode 字段：缺省为叠放。
    private enum CodingKeys: String, CodingKey { case enabled, mode, shape, size, sideHeight, x, y, mirrored, shadow, cornerRadius, aspect, belowScreen, shrinkOnFocus, focusedScale }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .overlay
        shape = try container.decode(Shape.self, forKey: .shape)
        size = try container.decode(Double.self, forKey: .size)
        sideHeight = try container.decodeIfPresent(Double.self, forKey: .sideHeight) ?? 0.45
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        mirrored = try container.decode(Bool.self, forKey: .mirrored)
        shadow = try container.decode(Bool.self, forKey: .shadow)
        // 旧工程没有圆角字段：圆形照旧是正圆，圆角矩形照旧 0.14。
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? (shape == .circle && mode == .overlay ? 0.5 : 0.14)
        aspect = try container.decodeIfPresent(Double.self, forKey: .aspect) ?? 4.0 / 3.0
        belowScreen = try container.decodeIfPresent(Bool.self, forKey: .belowScreen) ?? false
        shrinkOnFocus = try container.decodeIfPresent(Bool.self, forKey: .shrinkOnFocus) ?? true
        focusedScale = try container.decodeIfPresent(Double.self, forKey: .focusedScale) ?? 0.7
    }
}

import AppKit
import CoreGraphics
import CoreImage
import CoreText
import EditingCore

/// 把文字层画到成片上。排版走 Core Text，所以中英混排、标点避头尾、字体回退都由系统负责。
///
/// 分两步：先把"静态的一段文字"排好版画成位图并缓存，再每帧只做位移、缩放与不透明度。
/// 逐帧重新排版在 4K 下是实打实的开销，而一段文字在它整个生命周期里通常只有一种排版。
///
/// 尺寸全部按 1080 参考高度书写，渲染时按输出画面高度等比缩放；预览和导出因此完全一致。
public final class TextRenderer: @unchecked Sendable {
    public static let shared = TextRenderer()
    /// 尺寸的参考高度。
    public static let referenceHeight: Double = 1080

    private struct Key: Hashable {
        let text: String
        let revealed: Int
        let size: Double
        let weight: Double
        let family: String
        let italic: Bool
        let alignment: String
        let lineHeight: Double
        let tracking: Double
        let maxWidth: Double
        let color: String
        let plate: Bool
        let plateColor: String
        let plateOpacity: Double
        let platePadding: Double
        let plateRadius: Double
        let plateFull: Bool
        let shadow: Bool
        let shadowOpacity: Double
        let shadowBlur: Double
        let shadowOffset: Double
        let boxWidth: Double
        let boxHeight: Double
        /// 文字盒的位置也要进键：缓存里存的是画布坐标的位图与外框，左右分屏互换时盒子一样大只是左右对调，
        /// 只按大小取缓存会把上一侧的位图原地还给你——文字留在原来那一栏，压在画面上。
        let boxX: Double
        let boxY: Double
        let anchorX: Double
        let anchorY: Double
        let light: Bool
        /// 逐词高亮：字符范围、颜色与是否画药丸底。
        let highlightLocation: Int
        let highlightLength: Int
        let highlightColor: String
        let highlightMix: Double
        let highlightPill: Bool
    }

    /// 逐词高亮的参数。字幕用；文字层传 nil。
    public struct Highlight: Equatable, Sendable {
        public var location: Int
        public var length: Int
        /// 高亮词本身的颜色。药丸模式下这是压在药丸上的字色，必须和药丸拉开明度。
        public var color: TextSegment.Palette
        /// 药丸底的颜色；`pill` 为假时不用。
        public var pillColor: TextSegment.Palette
        /// 0…1 的过渡权重，词与词之间平滑切换。
        public var progress: Double
        public var pill: Bool
        public init(location: Int, length: Int, color: TextSegment.Palette, pillColor: TextSegment.Palette = .amber,
                    progress: Double, pill: Bool) {
            self.location = location; self.length = length; self.color = color
            self.pillColor = pillColor; self.progress = progress; self.pill = pill
        }
        /// 压在某个底色上时该用什么字色：底色亮就用墨黑，底色暗就用白。
        public static func readableGlyphColor(on background: TextSegment.Palette) -> TextSegment.Palette {
            let rgb = background.rgb
            let luma = 0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2
            return luma > 0.55 ? .ink : .white
        }
    }
    /// 排好版的一段文字：位图加它在画布上的位置。
    private struct Rendered {
        let image: CIImage
        let frame: CGRect
        /// 文字本身（不含底板与阴影）的包围盒，画布坐标。
        let textFrame: CGRect
        /// 眼睛看得见的那一块：有底板就是底板（底板一定比文字大一圈），没有就是文字本身。不含阴影的模糊。
        let visibleFrame: CGRect
    }
    private var cache: [Key: Rendered] = [:]
    private var order: [Key] = []
    private var weights: [Key: Int] = [:]
    private var bytes = 0
    private let lock = NSLock()
    private static let capacity = 48
    /// 只按"条数 48"封顶不够：4K 画布下一张满幅文字位图就是 33 MB，48 张能吃掉一两个 G。
    /// 条数与字节双上限，两条谁先到就先淘汰谁。
    private static let byteLimit = 192 * 1024 * 1024

    public init() {}

    public func clear() {
        lock.lock(); cache.removeAll(); order.removeAll(); weights.removeAll(); bytes = 0; lock.unlock()
    }

    /// 一段文字在这一帧的画面。`lightBackground` 为真时"自动"色取墨黑，否则取白。
    /// 返回 nil 表示这一帧不用画（文字为空、完全透明或排不出内容）。
    public func image(for state: TextState, canvas: CGSize, lightBackground: Bool, highlight: Highlight? = nil) -> CIImage? {
        guard canvas.width > 1, canvas.height > 1 else { return nil }
        let alpha = state.animation.alpha * state.segment.opacity
        guard alpha > 0.002 else { return nil }
        guard let rendered = layout(state, canvas: canvas, lightBackground: lightBackground, highlight: highlight) else { return nil }
        var image = rendered.image
        if let transform = Self.animation(for: state, center: CGPoint(x: rendered.textFrame.midX, y: rendered.textFrame.midY),
                                          canvas: canvas) {
            image = image.transformed(by: transform)
        }
        if alpha < 0.998 {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            ])
        }
        return image.cropped(to: CGRect(origin: .zero, size: canvas))
    }

    /// 这一帧的动画变换：缩放绕文字中心，位移按画面高度的比例；两者都不改变已经排好的版。
    /// 画面和画布上的选中框都从这里取，少一处就会在进出场那几帧对不上（上滑进场时框停在终点、文字还在下面）。
    private static func animation(for state: TextState, center: CGPoint, canvas: CGSize) -> CGAffineTransform? {
        let scale = state.animation.scale
        let dy = -state.animation.offset * canvas.height
        guard abs(scale - 1) > 0.0005 || abs(dy) > 0.01 else { return nil }
        return CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y + dy))
    }

    /// 文字本身的包围盒（画布坐标，左下原点），不含底板与阴影，**已经跟着这一帧的动画走**。
    public func textFrame(for state: TextState, canvas: CGSize, lightBackground: Bool) -> CGRect? {
        guard let rendered = layout(state, canvas: canvas, lightBackground: lightBackground, highlight: nil) else { return nil }
        return Self.applying(rendered.textFrame, of: rendered, state: state, canvas: canvas)
    }

    /// 画布上选中框该框住的那一块：有底板时是底板（底板比文字大一圈，只框文字的话框会落在底板里面，看着就是错位），
    /// 没有底板时就是文字自己。阴影不算——它是软的，框住它反而虚。同样跟着这一帧的动画走。
    public func visibleFrame(for state: TextState, canvas: CGSize, lightBackground: Bool) -> CGRect? {
        guard let rendered = layout(state, canvas: canvas, lightBackground: lightBackground, highlight: nil) else { return nil }
        return Self.applying(rendered.visibleFrame, of: rendered, state: state, canvas: canvas)
    }

    private static func applying(_ rect: CGRect, of rendered: Rendered, state: TextState, canvas: CGSize) -> CGRect {
        let center = CGPoint(x: rendered.textFrame.midX, y: rendered.textFrame.midY)
        guard let transform = animation(for: state, center: center, canvas: canvas) else { return rect }
        return rect.applying(transform)
    }

    /// 当前版式下文字可用的矩形（画布坐标，左下原点）。
    /// 几何定义在 `TextSegment.textBoxFraction`（归一化、左上原点），这里只换算坐标系，
    /// 好让画面层的摆放与文字盒始终出自同一处定义。
    public static func box(for segment: TextSegment, canvas: CGSize) -> CGRect {
        let fraction = segment.textBoxFraction
        return CGRect(x: fraction.minX * canvas.width,
                      y: (1 - fraction.maxY) * canvas.height,
                      width: fraction.width * canvas.width,
                      height: fraction.height * canvas.height)
    }

    // MARK: 排版

    private func layout(_ state: TextState, canvas: CGSize, lightBackground: Bool, highlight: Highlight?) -> Rendered? {
        let segment = state.segment
        guard !segment.text.isEmpty else { return nil }
        let box = Self.box(for: segment, canvas: canvas)
        let key = Key(text: segment.text, revealed: min(state.revealedCount, segment.text.count),
                      size: segment.size, weight: segment.weight, family: segment.family.rawValue, italic: segment.italic,
                      alignment: segment.alignment.rawValue, lineHeight: segment.lineHeight, tracking: segment.tracking,
                      maxWidth: segment.maxWidth, color: segment.color.rawValue,
                      plate: segment.plate, plateColor: segment.plateColor.rawValue, plateOpacity: segment.plateOpacity,
                      platePadding: segment.platePadding, plateRadius: segment.plateRadius, plateFull: segment.plateFull,
                      shadow: segment.shadow, shadowOpacity: segment.shadowOpacity, shadowBlur: segment.shadowBlur,
                      shadowOffset: segment.shadowOffset,
                      boxWidth: box.width, boxHeight: box.height, boxX: box.minX, boxY: box.minY,
                      anchorX: segment.x, anchorY: segment.y,
                      light: lightBackground,
                      highlightLocation: highlight?.location ?? -1, highlightLength: highlight?.length ?? 0,
                      highlightColor: (highlight?.color.rawValue ?? "") + (highlight?.pillColor.rawValue ?? ""),
                      // 过渡权重量化到 1/16，避免每一帧都换缓存键。
                      highlightMix: ((highlight?.progress ?? 0) * 16).rounded() / 16,
                      highlightPill: highlight?.pill ?? false)
        lock.lock()
        if let hit = cache[key] {
            order.removeAll { $0 == key }; order.append(key)
            lock.unlock(); return hit
        }
        lock.unlock()
        guard let rendered = draw(state, box: box, canvas: canvas, lightBackground: lightBackground, highlight: highlight) else { return nil }
        // 位图按 RGBA8 估重；CIImage 是懒的，这里量的是它兑现之后的量级，用来限总量足够。
        let weight = max(1, Int(rendered.frame.width.rounded()) * Int(rendered.frame.height.rounded()) * 4)
        lock.lock()
        cache[key] = rendered; order.append(key); weights[key] = weight; bytes += weight
        while (order.count > Self.capacity || bytes > Self.byteLimit), order.count > 1, let oldest = order.first {
            order.removeFirst(); cache[oldest] = nil
            bytes -= weights.removeValue(forKey: oldest) ?? 0
        }
        lock.unlock()
        return rendered
    }

    private func draw(_ state: TextState, box: CGRect, canvas: CGSize, lightBackground: Bool, highlight: Highlight?) -> Rendered? {
        let segment = state.segment
        let unit = canvas.height / Self.referenceHeight
        let fontSize = max(1, segment.size * unit)
        let font = Self.font(family: segment.family, size: fontSize, weight: segment.weight, italic: segment.italic)
        let textColor = Self.color(segment.color, lightBackground: lightBackground)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch segment.alignment { case .leading: .left; case .center: .center; case .trailing: .right }
        // 行高直接钉死上下限，字体自身的行距不再参与，面板里的数值才对得上肉眼。
        let leading = max(1, fontSize * segment.lineHeight)
        paragraph.minimumLineHeight = leading; paragraph.maximumLineHeight = leading
        paragraph.lineBreakMode = .byWordWrapping

        let attributed = NSMutableAttributedString(string: segment.text, attributes: [
            .font: font, .foregroundColor: textColor, .paragraphStyle: paragraph,
            .kern: segment.tracking * unit,
        ])
        // 打字机：整段先排好版，再把还没"打"出来的字设成透明。这样揭示过程中版面一动不动。
        let total = attributed.length
        let revealed = max(0, min(total, state.revealedCount))
        if revealed < total {
            attributed.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: revealed, length: total - revealed))
        }
        // 逐词高亮：只换那几个字的颜色，排版一个像素都不动。
        var highlightRange: NSRange?
        if let highlight, highlight.length > 0, highlight.location >= 0, highlight.location + highlight.length <= total {
            let range = NSRange(location: highlight.location, length: highlight.length)
            highlightRange = range
            let target = Self.color(highlight.color, lightBackground: lightBackground)
            let mixed = textColor.blended(withFraction: min(1, max(0, highlight.progress)), of: target) ?? target
            attributed.addAttribute(.foregroundColor, value: mixed, range: range)
        }
        let limit = max(1, box.width * segment.maxWidth)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var fitRange = CFRange()
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                                    CGSize(width: limit, height: .greatestFiniteMagnitude), &fitRange)
        let textSize = CGSize(width: max(1, ceil(measured.width)), height: max(1, ceil(measured.height)))
        guard textSize.width.isFinite, textSize.height.isFinite else { return nil }

        // 锚点：x 按对齐方式落在文字块的左缘 / 中线 / 右缘；y 恒为整块文字的垂直中心。
        let anchorX = box.minX + segment.x * box.width
        let anchorY = box.maxY - segment.y * box.height
        let left = switch segment.alignment {
        case .leading: anchorX
        case .center: anchorX - textSize.width / 2
        case .trailing: anchorX - textSize.width
        }
        let textFrame = CGRect(x: left, y: anchorY - textSize.height / 2, width: textSize.width, height: textSize.height)

        let padding = segment.plate ? segment.platePadding * unit : 0
        var plateFrame = textFrame.insetBy(dx: -padding, dy: -padding)
        if segment.plate, segment.plateFull {
            plateFrame = CGRect(x: box.minX, y: plateFrame.minY, width: box.width, height: plateFrame.height)
        }
        // 位图要装下底板、阴影的模糊与偏移。
        let blur = segment.shadow ? segment.shadowBlur * unit : 0
        let offset = segment.shadow ? segment.shadowOffset * unit : 0
        var bounds = segment.plate ? plateFrame.union(textFrame) : textFrame
        bounds = bounds.insetBy(dx: -(blur + abs(offset) + 4), dy: -(blur + abs(offset) + 4))
        bounds = bounds.integral
        guard bounds.width >= 1, bounds.height >= 1, bounds.width < 20000, bounds.height < 20000 else { return nil }

        let width = Int(bounds.width), height = Int(bounds.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.setAllowsAntialiasing(true); context.setShouldSmoothFonts(true)

        if segment.plate {
            context.saveGState()
            let color = TextSegment.Palette.rgb(segment.plateColor, lightBackground: lightBackground)
            context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: segment.plateOpacity))
            let radius = min(segment.plateRadius * unit, min(plateFrame.width, plateFrame.height) / 2)
            context.addPath(CGPath(roundedRect: plateFrame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        // 阴影只给文字，底板不投影；否则底板下缘会拖出一条硬边。
        if segment.shadow, segment.shadowOpacity > 0 {
            context.setShadow(offset: CGSize(width: 0, height: -offset), blur: blur,
                              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: segment.shadowOpacity))
        }
        let path = CGPath(rect: CGRect(x: textFrame.minX, y: textFrame.minY, width: textFrame.width + 1, height: textFrame.height + 1), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        // 药丸底垫在字下面，而且不吃文字的阴影，所以先撤掉阴影画它，再恢复。
        if let highlightRange, highlight?.pill == true,
           let pill = Self.pillRect(frame: frame, range: highlightRange, origin: textFrame.origin, padding: fontSize * 0.18) {
            context.saveGState()
            context.setShadow(offset: .zero, blur: 0, color: nil)
            let color = Self.color(highlight?.pillColor ?? .amber, lightBackground: lightBackground)
            context.setFillColor(color.withAlphaComponent(min(1, max(0, highlight?.progress ?? 1)) * 0.85).cgColor)
            let radius = min(pill.height / 2, fontSize * 0.4)
            context.addPath(CGPath(roundedRect: pill, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
            context.restoreGState()
        }
        CTFrameDraw(frame, context)
        context.restoreGState()

        guard let cgImage = context.makeImage() else { return nil }
        let image = CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
        return Rendered(image: image, frame: bounds, textFrame: textFrame,
                        visibleFrame: segment.plate ? plateFrame.union(textFrame) : textFrame)
    }

    /// 高亮词在画布上的矩形。跨行时只取它落在的第一行——药丸本来就不该跨行。
    /// `origin` 是排版路径的左下角：`CTFrameGetLineOrigins` 给的是**相对路径**的坐标，
    /// 不加回去药丸会跑到画面左下角，而且因为它落在位图之外，看起来就像"根本没画"。
    static func pillRect(frame: CTFrame, range: NSRange, origin frameOrigin: CGPoint, padding: Double) -> CGRect? {
        // CFArray 里装的是 CTLine，用 `as? [CTLine]` 桥接在 Swift 6 下不保证成功；
        // 直接走 CFArray 接口，拿不到行就没有药丸，那正是这里最容易静默失效的地方。
        let array = CTFrameGetLines(frame)
        let count = CFArrayGetCount(array)
        guard count > 0 else { return nil }
        let lines = (0..<count).map { unsafeBitCast(CFArrayGetValueAtIndex(array, $0), to: CTLine.self) }
        var origins = [CGPoint](repeating: .zero, count: count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (number, line) in lines.enumerated() {
            let lineRange = CTLineGetStringRange(line)
            let lower = lineRange.location, upper = lineRange.location + lineRange.length
            guard range.location < upper, range.location + range.length > lower else { continue }
            let from = max(range.location, lower), to = min(range.location + range.length, upper)
            guard to > from else { continue }
            let startX = CTLineGetOffsetForStringIndex(line, from, nil)
            let endX = CTLineGetOffsetForStringIndex(line, to, nil)
            var ascent = CGFloat.zero, descent = CGFloat.zero, leading = CGFloat.zero
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let origin = CGPoint(x: origins[number].x + frameOrigin.x, y: origins[number].y + frameOrigin.y)
            return CGRect(x: origin.x + min(startX, endX) - padding, y: origin.y - descent - padding * 0.4,
                          width: abs(endX - startX) + padding * 2, height: ascent + descent + padding * 0.8)
        }
        return nil
    }

    // MARK: 字体与颜色

    static func font(family: TextSegment.Family, size: Double, weight: Double, italic: Bool) -> NSFont {
        let nsWeight = Self.weight(weight)
        var font: NSFont
        switch family {
        case .system: font = .systemFont(ofSize: size, weight: nsWeight)
        case .sans: font = NSFont(descriptor: NSFont.systemFont(ofSize: size, weight: nsWeight).fontDescriptor, size: size) ?? .systemFont(ofSize: size, weight: nsWeight)
        case .serif: font = Self.designed(.serif, size: size, weight: nsWeight)
        case .rounded: font = Self.designed(.rounded, size: size, weight: nsWeight)
        case .mono: font = .monospacedSystemFont(ofSize: size, weight: nsWeight)
        }
        if italic {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        return font
    }

    /// 系统字体的设计变体（衬线 / 圆体）；取不到就退回普通系统字体，不会失败。
    private static func designed(_ design: NSFontDescriptor.SystemDesign, size: Double, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// 300…900 就近取系统的字重档。苹方只有六档，中间值会落到相邻档上。
    static func weight(_ value: Double) -> NSFont.Weight {
        switch value {
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }

    static func color(_ palette: TextSegment.Palette, lightBackground: Bool) -> NSColor {
        let rgb = TextSegment.Palette.rgb(palette, lightBackground: lightBackground)
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
}

extension TextSegment.Palette {
    /// `auto` 按画布背景亮度在墨黑与白之间选；其余是固定色。
    /// 注意这是按**背景**判的，不是按录屏内容——逐帧读回像素来判亮度会把播放拖垮。
    /// 压在画面上的文字靠预设自带的阴影或底板保证可读，不靠这里换色。
    public static func rgb(_ palette: Self, lightBackground: Bool) -> (Double, Double, Double) {
        guard palette == .auto else { return palette.rgb }
        return lightBackground ? Self.ink.rgb : Self.white.rgb
    }
}

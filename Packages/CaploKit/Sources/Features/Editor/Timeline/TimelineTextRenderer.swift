import AppKit
import CoreText

/// 时间线标签只需要单行排版。使用固定字体、已解析颜色和显式 CGContext，
/// 避免把动态 NSColor / 段落样式交给 NSStringDrawingEngine 再转换成内部绘制属性。
@MainActor
enum TimelineTextRenderer {
    private struct FontKey: Hashable {
        let size: Double
        let bold: Bool
    }
    private static var fonts: [FontKey: CTFont] = [:]
    private struct ColorKey: Hashable {
        let color: NSColor
        let appearance: String
    }
    /// 解析动态颜色要切一次绘制外观，代价不小；时间线一帧要画几百个块，必须缓存。
    /// 键里带外观名，浅色 / 深色切换自然分开。
    private static var colors: [ColorKey: CGColor] = [:]
    private struct LineKey: Hashable {
        let text: String
        let size: Double
        let bold: Bool
        let color: NSColor
        let appearance: String
    }
    /// 排好版的整行。块标题在拖动期间一个字都不变，逐帧重新排版纯属浪费。
    private static var lines: [LineKey: (line: CTLine, width: Double, ascent: Double)] = [:]
    private struct MetricKey: Hashable {
        let text: String
        let size: Double
        let bold: Bool
    }
    private static var widths: [MetricKey: Double] = [:]

    static func resolvedColor(_ color: NSColor, appearance: NSAppearance) -> CGColor {
        let key = ColorKey(color: color, appearance: appearance.name.rawValue)
        if let cached = colors[key] { return cached }
        var result = NSColor.clear.cgColor
        appearance.performAsCurrentDrawingAppearance {
            // 设计令牌均为 RGB 颜色；先固定到 sRGB，使 Core Text 不依赖后续绘制外观变化。
            result = (color.usingColorSpace(.sRGB) ?? color).cgColor
        }
        if colors.count >= 256 { colors.removeAll(keepingCapacity: true) }
        colors[key] = result
        return result
    }

    /// 单行文字的宽度。块标题的宽度每帧都要量一次来决定居中还是截断，量一次存下来就够。
    static func width(_ text: String, size: Double, bold: Bool) -> Double {
        let key = MetricKey(text: text, size: size, bold: bold)
        if let cached = widths[key] { return cached }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: size, bold: bold)
        ]))
        let value = ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
        if widths.count >= 512 { widths.removeAll(keepingCapacity: true) }
        widths[key] = value
        return value
    }

    private static func font(size: Double, bold: Bool) -> CTFont {
        let key = FontKey(size: size, bold: bold)
        if let cached = fonts[key] { return cached }
        let native = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
        let value = CTFontCreateWithName(native.fontName as CFString, size, nil)
        // 字号来自有限的界面样式；为异常输入保留上限，不能让绘制缓存无限增长。
        if fonts.count >= 16 { fonts.removeAll(keepingCapacity: true) }
        fonts[key] = value
        return value
    }

    /// 外观变了（浅色 / 深色）就把解析结果全丢掉重来。
    static func invalidateAppearanceCaches() {
        colors.removeAll(keepingCapacity: true)
        lines.removeAll(keepingCapacity: true)
    }

    @discardableResult
    static func draw(_ text: String, in rect: CGRect, color: NSColor, size: Double = 10, bold: Bool = false,
                     appearance: NSAppearance, context: CGContext, flipped: Bool) -> Bool {
        // CGRect 的 width / height 会标准化负尺寸，校验必须读取原始 size。
        guard !text.isEmpty, rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite, rect.size.width > 0, rect.size.height > 0,
              size.isFinite, size > 0 else { return false }
        let lineKey = LineKey(text: text, size: size, bold: bold, color: color, appearance: appearance.name.rawValue)
        let cached: (line: CTLine, width: Double, ascent: Double)
        if let hit = lines[lineKey] { cached = hit }
        else {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font(size: size, bold: bold),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): resolvedColor(color, appearance: appearance)
            ]
            let full = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            var ascent = CGFloat.zero
            let measured = CTLineGetTypographicBounds(full, &ascent, nil, nil)
            if lines.count >= 512 { lines.removeAll(keepingCapacity: true) }
            cached = (full, measured, ascent)
            lines[lineKey] = cached
        }
        let ascent = cached.ascent
        let line: CTLine
        if cached.width > rect.width {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font(size: size, bold: bold),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): resolvedColor(color, appearance: appearance)
            ]
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            line = CTLineCreateTruncatedLine(cached.line, rect.width, .end, token) ?? cached.line
        } else { line = cached.line }

        let previousTextMatrix = context.textMatrix, previousTextPosition = context.textPosition
        context.saveGState()
        defer {
            context.restoreGState()
            // Core Graphics 的文字矩阵和位置不应泄漏到同一帧里的其他文字绘制。
            context.textMatrix = previousTextMatrix; context.textPosition = previousTextPosition
        }
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        if flipped { context.translateBy(x: 0, y: rect.height); context.scaleBy(x: 1, y: -1) }
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 0, y: rect.height - ascent)
        CTLineDraw(line, context)
        return true
    }
}

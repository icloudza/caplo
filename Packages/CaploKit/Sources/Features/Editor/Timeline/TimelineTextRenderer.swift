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

    static func resolvedColor(_ color: NSColor, appearance: NSAppearance) -> CGColor {
        var result = NSColor.clear.cgColor
        appearance.performAsCurrentDrawingAppearance {
            // 设计令牌均为 RGB 颜色；先固定到 sRGB，使 Core Text 不依赖后续绘制外观变化。
            result = (color.usingColorSpace(.sRGB) ?? color).cgColor
        }
        return result
    }

    @discardableResult
    static func draw(_ text: String, in rect: CGRect, color: NSColor, size: Double = 10, bold: Bool = false,
                     appearance: NSAppearance, context: CGContext, flipped: Bool) -> Bool {
        // CGRect 的 width / height 会标准化负尺寸，校验必须读取原始 size。
        guard !text.isEmpty, rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite, rect.size.width > 0, rect.size.height > 0,
              size.isFinite, size > 0 else { return false }
        let key = FontKey(size: size, bold: bold)
        let font: CTFont
        if let cached = fonts[key] { font = cached }
        else {
            let native = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
            font = CTFontCreateWithName(native.fontName as CFString, size, nil)
            // 字号来自有限的界面样式；为异常输入保留上限，不能让绘制缓存无限增长。
            if fonts.count >= 16 { fonts.removeAll(keepingCapacity: true) }
            fonts[key] = font
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): resolvedColor(color, appearance: appearance)
        ]
        let fullLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent = CGFloat.zero
        let width = CTLineGetTypographicBounds(fullLine, &ascent, nil, nil)
        let line: CTLine
        if width > rect.width {
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            line = CTLineCreateTruncatedLine(fullLine, rect.width, .end, token) ?? fullLine
        } else { line = fullLine }

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

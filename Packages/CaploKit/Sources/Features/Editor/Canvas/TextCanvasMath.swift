import CoreGraphics

/// 画布上拖文字的纯几何：整块文字框按位移挪过去、吸附到画布边 / 留白边 / 中线与画面块，
/// 再把吸附之后的位移换回文字的锚点。吸附用的是「自定义布局」那一套，手感与参考线完全一致。
enum TextCanvasMath {
    /// 把手与选中框画在文字框外扩这么多点的那一圈上。
    static let handleOutset: CGFloat = 6
    /// 画把手和判命中必须用同一个框：只画在外扩的框上、却拿没外扩的框判命中，
    /// 点在看得见的把手外侧半圈就会判成"拖块体"，表现是拉角变成了挪位置。
    static func handleFrame(_ textFrame: CGRect) -> CGRect { textFrame.insetBy(dx: -handleOutset, dy: -handleOutset) }

    /// 画布上只有两件事：抓四角等比改字号，抓框体挪位置。
    /// 折行宽度（`maxWidth`）不放在画布上——它一改就可能多一行少一行，横着拖会把高度也带着变；
    /// 那一项在「排版 → 最大宽度」的卡尺里调，有数值看得见。
    enum Handle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight, body
    }

    /// 命中判定：四角改字号，其余落在框里就是挪位置。
    static func handle(at point: CGPoint, textFrame: CGRect, cornerSize: CGFloat, slop: CGFloat) -> Handle? {
        let frame = handleFrame(textFrame)
        // 与遮罩同一条：文字盒被分屏压窄时，把手的命中区不收窄的话就连成一片、盒体拖不动。
        let reach = MaskCanvasMath.handleReach(frame, size: cornerSize, slop: slop)
        let anchors: [(Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: frame.minX, y: frame.maxY)),
            (.topRight, CGPoint(x: frame.maxX, y: frame.maxY)),
            (.bottomLeft, CGPoint(x: frame.minX, y: frame.minY)),
            (.bottomRight, CGPoint(x: frame.maxX, y: frame.minY)),
        ]
        for (handle, center) in anchors where abs(point.x - center.x) <= reach && abs(point.y - center.y) <= reach {
            return handle
        }
        return frame.insetBy(dx: -4, dy: -4).contains(point) ? .body : nil
    }

    /// 拖角等比改字号：按指针相对按下位置离不动点更远 / 更近的那点位移算，位移用**文字自身**的对角线折算成比例。
    /// 不能拿编辑框的对角线折算——框画的是排版那一栏，可以宽到文字的三四倍，那样拉角几乎推不动字号。
    static func size(_ current: Double, distance: CGFloat, startDistance: CGFloat,
                     glyph: CGSize, range: ClosedRange<Double>) -> Double {
        let scale = max(1, hypot(glyph.width, glyph.height))
        let next = current * (1 + Double(distance - startDistance) / Double(scale))
        return min(range.upperBound, max(range.lowerBound, next))
    }

    /// 等比改字号时的不动点：抓哪个角就以对角为轴，抓框体以框心为轴。位置同样按把手那一圈算。
    static func pivot(for handle: Handle, textFrame: CGRect) -> CGPoint {
        let frame = handleFrame(textFrame)
        return switch handle {
        case .topLeft: CGPoint(x: frame.maxX, y: frame.minY)
        case .topRight: CGPoint(x: frame.minX, y: frame.minY)
        case .bottomLeft: CGPoint(x: frame.maxX, y: frame.maxY)
        case .bottomRight: CGPoint(x: frame.minX, y: frame.maxY)
        default: CGPoint(x: frame.midX, y: frame.midY)
        }
    }
    /// - Parameters:
    ///   - anchor: 按下时的锚点（文字盒内归一化，y 从上往下量）。
    ///   - rect: 按下时文字框在视图里的位置（y 向上）。
    ///   - translation: 鼠标位移（视图坐标）。
    ///   - box: 文字盒的尺寸，锚点按它换算。
    static func drag(anchor: CGPoint, rect: CGRect, translation: CGSize, box: CGSize,
                     canvas: CGRect, inner: CGRect, targets: [CGRect]) -> (anchor: CGPoint, guides: [CustomLayoutMath.Guide]) {
        guard box.width > 1, box.height > 1 else { return (anchor, []) }
        let moved = rect.offsetBy(dx: translation.width, dy: translation.height)
        let snapped = CustomLayoutMath.snap(moved, canvas: canvas, inner: inner, targets: targets)
        // 锚点的 y 是从上往下量的，视图是 y 向上，所以纵向要取反。
        let dx = (snapped.rect.minX - rect.minX) / box.width
        let dy = -(snapped.rect.minY - rect.minY) / box.height
        return (CGPoint(x: min(1.2, max(-0.2, anchor.x + dx)), y: min(1.2, max(-0.2, anchor.y + dy))), snapped.guides)
    }
}

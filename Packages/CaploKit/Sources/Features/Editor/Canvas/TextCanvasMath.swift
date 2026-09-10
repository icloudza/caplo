import CoreGraphics
import EditingCore

/// 画布上拖文字的纯几何：整块文字框按位移挪过去、吸附到画布边 / 留白边 / 中线与画面块，
/// 再把吸附之后的位移换回文字的锚点。吸附用的是「自定义布局」那一套，手感与参考线完全一致。
enum TextCanvasMath {
    /// 把手与选中框画在文字框外扩这么多点的那一圈上。
    static let handleOutset: CGFloat = 6
    /// 画把手和判命中必须用同一个框：只画在外扩的框上、却拿没外扩的框判命中，
    /// 点在看得见的把手外侧半圈就会判成"拖块体"，表现是拉角变成了挪位置。
    static func handleFrame(_ textFrame: CGRect) -> CGRect { textFrame.insetBy(dx: -handleOutset, dy: -handleOutset) }

    /// 画布上三件事：抓四角等比改字号，抓左右边把承载文字的区域放宽 / 收窄，抓框体挪位置。
    /// 左右边改的是折行宽度（`maxWidth`），字号一点不动——原来只有「排版 → 文本框宽度」那把卡尺能调。
    enum Handle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight, left, right, body
    }

    /// 命中判定：四角改字号，左右边改承载宽度，其余落在文字框里就是挪位置。
    /// 承载区可以比文字宽出一大截，所以左右边按它的边判，四角仍按文字框判——
    /// 两者重合时先判四角，免得角上一点被抢成拉宽。
    static func handle(at point: CGPoint, textFrame: CGRect, carryFrame: CGRect,
                       cornerSize: CGFloat, slop: CGFloat) -> Handle? {
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
        let carry = handleFrame(carryFrame)
        if point.y >= carry.minY - slop, point.y <= carry.maxY + slop {
            let side = MaskCanvasMath.handleReach(carry, size: cornerSize, slop: slop)
            if abs(point.x - carry.minX) <= side { return .left }
            if abs(point.x - carry.maxX) <= side { return .right }
        }
        return frame.insetBy(dx: -4, dy: -4).contains(point) ? .body : nil
    }

    /// 拖左右边：只改承载文字的宽度，按住的那条边跟指针走、对面那条边钉住。
    /// 宽度存成占文字盒的比例，所以分屏时它天然被那一栏关住，换版式也不用重算。
    /// 锚点按对齐方式补偿：居中要挪半个变化量，靠左拖右边根本不用挪。
    static func widen(maxWidth: Double, anchorX: Double, alignment: TextSegment.Alignment, handle: Handle,
                      translation: CGFloat, boxWidth: CGFloat,
                      range: ClosedRange<Double> = TextSegment.maxWidthRange) -> (maxWidth: Double, x: Double) {
        guard boxWidth > 1, handle == .left || handle == .right else { return (maxWidth, anchorX) }
        let delta = Double(translation) / Double(boxWidth)
        let next = min(range.upperBound, max(range.lowerBound, maxWidth + (handle == .right ? delta : -delta)))
        // 钳过之后实际生效的变化量：拖到头了锚点也就不该再动，否则文字会继续往一边爬。
        let applied = next - maxWidth
        let shift: Double = switch alignment {
        case .leading: handle == .right ? 0 : -applied
        case .center: (handle == .right ? applied : -applied) / 2
        case .trailing: handle == .right ? applied : 0
        }
        return (next, min(1.2, max(-0.2, anchorX + shift)))
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

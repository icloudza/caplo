import CoreGraphics
import Testing
import EditingCore
@testable import Features

/// 画布上拖文字：与「自定义布局」同一套吸附——贴近画布中线 / 边 / 留白边 / 画面块就吸上去并画参考线。
struct TextCanvasDragTests {
    private let canvas = CGRect(x: 0, y: 0, width: 800, height: 450)
    private var inner: CGRect { canvas.insetBy(dx: 40, dy: 40) }
    /// 文字框：200×60，起始时中线离画布中线还差 5 点（在 8 点吸附距离内）。
    private var rect: CGRect { CGRect(x: 295, y: 190, width: 200, height: 60) }

    @Test func nearTheCentreItSnapsAndDrawsTheCrosshair() {
        let box = CGSize(width: 640, height: 360)
        let moved = TextCanvasMath.drag(anchor: CGPoint(x: 0.5, y: 0.5), rect: rect, translation: .zero,
                                        box: box, canvas: canvas, inner: inner, targets: [])
        // 横向差 5 点、纵向差 5 点，两条都吸上，就是一个十字。
        #expect(moved.guides.contains(.vertical(canvas.midX)))
        #expect(moved.guides.contains(.horizontal(canvas.midY)))
        // 吸上之后锚点正好把文字框推到中线上：两个方向都挪了 5 点，锚点的 y 向下量所以要减。
        #expect(abs(moved.anchor.x - (0.5 + 5 / box.width)) < 0.0001)
        #expect(abs(moved.anchor.y - (0.5 - 5 / box.height)) < 0.0001)
    }

    @Test func farFromEveryLineNothingSnaps() {
        let box = CGSize(width: 640, height: 360)
        let translation = CGSize(width: 60, height: 60)
        let moved = TextCanvasMath.drag(anchor: CGPoint(x: 0.5, y: 0.5), rect: rect, translation: translation,
                                        box: box, canvas: canvas, inner: inner, targets: [])
        #expect(moved.guides.isEmpty)
        #expect(abs(moved.anchor.x - (0.5 + translation.width / box.width)) < 0.0001)
        #expect(abs(moved.anchor.y - (0.5 - translation.height / box.height)) < 0.0001)
    }

    @Test func itAlsoSnapsToThePictureBlock() {
        let box = CGSize(width: 640, height: 360)
        // 画面块的左缘在 300，文字框左缘拖到 296：差 4 点，吸上去。
        let picture = CGRect(x: 300, y: 60, width: 400, height: 330)
        let moved = TextCanvasMath.drag(anchor: CGPoint(x: 0.5, y: 0.5), rect: rect.offsetBy(dx: 1, dy: 0), translation: .zero,
                                        box: box, canvas: canvas, inner: inner, targets: [picture])
        #expect(moved.guides.contains(.vertical(picture.minX)))
    }

    /// 把手画在外扩 6 点的那一圈上，命中判定必须用同一个框：
    /// 点在看得见的把手正中，判出来就得是那个把手，不能是"拖块体"。
    @Test(arguments: [CGRect(x: 295, y: 190, width: 200, height: 60),
                      // 一个字的小框：把手圈比文字框大一整圈，旧写法在这里连角都点不中。
                      CGRect(x: 393, y: 217, width: 14, height: 16)])
    func everyDrawnHandleIsHitWhereItIsDrawn(rect: CGRect) {
        let frame = TextCanvasMath.handleFrame(rect)
        let cases: [(TextCanvasMath.Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: frame.minX, y: frame.maxY)),
            (.topRight, CGPoint(x: frame.maxX, y: frame.maxY)),
            (.bottomLeft, CGPoint(x: frame.minX, y: frame.minY)),
            (.bottomRight, CGPoint(x: frame.maxX, y: frame.minY)),
        ]
        for (expected, point) in cases {
            let hit = TextCanvasMath.handle(at: point, textFrame: rect, carryFrame: rect, cornerSize: 12, slop: 5)
            #expect(hit == expected, "点在 \(expected) 把手正中，判成了 \(String(describing: hit))")
        }
        // 框正中是拖块体，框外一大截什么都不是。
        #expect(TextCanvasMath.handle(at: CGPoint(x: rect.midX, y: rect.midY), textFrame: rect, carryFrame: rect, cornerSize: 12, slop: 5) == .body)
        #expect(TextCanvasMath.handle(at: CGPoint(x: rect.maxX + 200, y: rect.midY), textFrame: rect, carryFrame: rect, cornerSize: 12, slop: 5) == nil)
    }

    /// 抓住某个角拉，不动点是对角——同样按把手那一圈算。
    @Test func theCornerPivotIsTheOppositeCorner() {
        let frame = TextCanvasMath.handleFrame(rect)
        #expect(TextCanvasMath.pivot(for: .bottomRight, textFrame: rect) == CGPoint(x: frame.minX, y: frame.maxY))
        #expect(TextCanvasMath.pivot(for: .topLeft, textFrame: rect) == CGPoint(x: frame.maxX, y: frame.minY))
        #expect(TextCanvasMath.pivot(for: .body, textFrame: rect) == CGPoint(x: frame.midX, y: frame.midY))
    }

    /// 拉角改字号：按下那一刻不能跳，灵敏度只跟文字自身的大小有关，与编辑框画多大无关。
    @Test func draggingACornerScalesByTheGlyph() {
        let glyph = CGSize(width: 164, height: 50), diagonal = hypot(164.0, 50.0)
        let range = 26.0...200.0
        // 按下不动：一点不变。
        #expect(TextCanvasMath.size(96, distance: 300, startDistance: 300, glyph: glyph, range: range) == 96)
        // 往外拉 47 点：按文字对角线折算，约 +27%。
        let bigger = TextCanvasMath.size(96, distance: 347, startDistance: 300, glyph: glyph, range: range)
        #expect(abs(bigger - 96 * (1 + 47 / diagonal)) < 0.0001 && bigger > 96 * 1.25)
        // 同样的位移，起始距离再远也不该变得迟钝。
        let farther = TextCanvasMath.size(96, distance: 660, startDistance: 613, glyph: glyph, range: range)
        #expect(abs(farther - bigger) < 0.0001)
        // 往回拉变小，两端封在字号区间里。
        #expect(TextCanvasMath.size(96, distance: 0, startDistance: 9000, glyph: glyph, range: range) == range.lowerBound)
        #expect(TextCanvasMath.size(96, distance: 9000, startDistance: 0, glyph: glyph, range: range) == range.upperBound)
    }

    @Test func anchorsNeverRunOffTheBox() {
        let box = CGSize(width: 100, height: 100)
        let far = TextCanvasMath.drag(anchor: CGPoint(x: 0.5, y: 0.5), rect: rect, translation: CGSize(width: 9000, height: -9000),
                                      box: box, canvas: canvas, inner: inner, targets: [])
        #expect(far.anchor.x == 1.2 && far.anchor.y == 1.2)
    }

    @Test func draggingASideWidensTheCarryingAreaWithoutTouchingTheFontSize() {
        // 抓右边往右拖：承载宽度变大，左缘钉住不动（居中对齐时靠锚点右移半个变化量补偿）。
        let widened = TextCanvasMath.widen(maxWidth: 0.4, anchorX: 0.5, alignment: .center, handle: .right,
                                           translation: 100, boxWidth: 1000)
        #expect(abs(widened.maxWidth - 0.5) < 0.000001 && abs(widened.x - 0.55) < 0.000001)
        // 抓左边往左拖同样是变宽，锚点往左挪半个变化量，右缘钉住。
        let leftward = TextCanvasMath.widen(maxWidth: 0.4, anchorX: 0.5, alignment: .center, handle: .left,
                                            translation: -100, boxWidth: 1000)
        #expect(abs(leftward.maxWidth - 0.5) < 0.000001 && abs(leftward.x - 0.45) < 0.000001)
        // 靠左对齐：拖右边左缘本来就不动，锚点一动不动；拖左边才补偿一整个变化量。
        #expect(TextCanvasMath.widen(maxWidth: 0.4, anchorX: 0.3, alignment: .leading, handle: .right,
                                     translation: 100, boxWidth: 1000).x == 0.3)
        let leadingLeft = TextCanvasMath.widen(maxWidth: 0.4, anchorX: 0.3, alignment: .leading, handle: .left,
                                               translation: -100, boxWidth: 1000)
        #expect(abs(leadingLeft.x - 0.2) < 0.000001)
        // 靠右对齐是镜像：拖左边锚点不动，拖右边补偿一整个变化量。
        #expect(TextCanvasMath.widen(maxWidth: 0.4, anchorX: 0.7, alignment: .trailing, handle: .left,
                                     translation: -100, boxWidth: 1000).x == 0.7)
        // 上限就是文字盒本身，分屏时那一栏就是文字盒，所以永远越不出这一栏；
        // 拖到头之后锚点也停住，不会继续往一边爬。
        let clamped = TextCanvasMath.widen(maxWidth: 0.9, anchorX: 0.5, alignment: .center, handle: .right,
                                           translation: 900, boxWidth: 1000)
        #expect(clamped.maxWidth == 1 && abs(clamped.x - 0.55) < 0.000001)
        let floored = TextCanvasMath.widen(maxWidth: 0.25, anchorX: 0.5, alignment: .center, handle: .right,
                                           translation: -900, boxWidth: 1000)
        #expect(floored.maxWidth == TextSegment.maxWidthRange.lowerBound)
        // 字号那一路完全不参与：拖边不经过 size(...)，这里确认两条路互不相干。
        #expect(TextCanvasMath.widen(maxWidth: 0.4, anchorX: 0.5, alignment: .center, handle: .body,
                                     translation: 100, boxWidth: 1000).maxWidth == 0.4)
    }

    @Test func sideHandlesSitOnTheCarryingEdgesAndCornersWinWhenTheyOverlap() {
        let text = CGRect(x: 400, y: 240, width: 200, height: 60)
        let carry = CGRect(x: 300, y: 240, width: 400, height: 60)
        func hit(_ x: CGFloat, _ y: CGFloat) -> TextCanvasMath.Handle? {
            TextCanvasMath.handle(at: CGPoint(x: x, y: y), textFrame: text, carryFrame: carry, cornerSize: 12, slop: 5)
        }
        let frame = TextCanvasMath.handleFrame(carry)
        #expect(hit(frame.minX, frame.midY) == .left)
        #expect(hit(frame.maxX, frame.midY) == .right)
        // 承载区之外、文字框之外，什么都不是。
        #expect(hit(frame.minX - 40, frame.midY) == nil)
        // 文字框里仍然是挪位置，不会被宽出去的承载区抢走。
        #expect(hit(text.midX, text.midY) == .body)
        // 承载区与文字框一样宽时，角上那一点归四角，不归拉宽。
        let corner = TextCanvasMath.handleFrame(text)
        #expect(TextCanvasMath.handle(at: CGPoint(x: corner.minX, y: corner.maxY), textFrame: text, carryFrame: text,
                                      cornerSize: 12, slop: 5) == .topLeft)
    }
}
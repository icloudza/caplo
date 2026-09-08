import CoreGraphics
import EditingCore

/// 时间宽度与操作宽度分开：缩小只扩大可点击外观，不改变素材时间或吸附边界。
enum TimelineInteractionGeometry {
    static let minimumBlockWidth = 44.0
    static let edgeWidth = 8.0
    static func blockRect(start: Double, duration: Double, scale: Double, offset: Double, header: Double, y: Double, height: Double) -> CGRect {
        CGRect(x: header + (start - offset) * scale, y: y,
               width: max(minimumBlockWidth, duration * scale), height: height)
    }
    static func hitEdge(at point: CGPoint, rect: CGRect) -> VideoEdit.FocusDragEdge? {
        guard rect.insetBy(dx: -4, dy: -3).contains(point) else { return nil }
        if point.x <= rect.minX + edgeWidth { return .leading }
        if point.x >= rect.maxX - edgeWidth { return .trailing }
        return .body
    }
    /// 返回移除拖动行后的插入槽；半行阈值用于判断放在目标行的上方还是下方。
    static func insertionSlot(y: Double, top: Double, scroll: Double, rowHeight: Double, source: Int, count: Int) -> Int {
        let boundary = min(count, max(0, Int(floor((y - top + scroll) / rowHeight + 0.5))))
        return min(max(0, count - 1), boundary > source ? boundary - 1 : boundary)
    }
}

import CoreGraphics

/// 接受显示器本地左上角坐标，支持任意方向拖选并裁剪到显示器内部。
public enum CaptureRegion {
    public static func clampedDrag(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect {
        guard [start.x, start.y, end.x, end.y, bounds.width, bounds.height].allSatisfy(\.isFinite) else { return .zero }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
        return rect.isNull ? .zero : rect.integral.intersection(bounds)
    }
}

import CoreGraphics
import Foundation

/// 主体和轨头拖动使用径向阻力，过滤点击抖动；启动后抵扣死区，避免首次移动突然跳过阈值距离。
/// 激活状态由视口保存，此处始终根据起点求位移，拖回起点可自然恢复原来的时间与行位置。
enum TimelineDragIntent {
    static func shouldBegin(from: CGPoint, to: CGPoint, threshold: Double = 8) -> Bool {
        guard threshold.isFinite, let vector = vector(from: from, to: to) else { return false }
        return vector.distance > max(0, threshold)
    }

    static func displacement(from: CGPoint, to: CGPoint, threshold: Double = 8) -> CGPoint {
        guard threshold.isFinite, let vector = vector(from: from, to: to) else { return .zero }
        let radius = max(0, threshold)
        guard vector.distance > radius else { return .zero }
        let remaining = vector.distance - radius
        return CGPoint(x: vector.x / vector.distance * remaining, y: vector.y / vector.distance * remaining)
    }

    private static func vector(from: CGPoint, to: CGPoint) -> (x: Double, y: Double, distance: Double)? {
        guard from.x.isFinite, from.y.isFinite, to.x.isFinite, to.y.isFinite else { return nil }
        let x = Double(to.x - from.x), y = Double(to.y - from.y), distance = hypot(x, y)
        guard distance.isFinite else { return nil }
        return (x, y, distance)
    }
}

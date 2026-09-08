import Foundation
import CoreGraphics

/// 人像位置相对可移动区域归一化，左上为零；更换画布比例后仍保留边距且不会出界。
/// 镜头聚焦只变换屏幕，人像作为最后一层独立合成。
public struct CameraLayout: Codable, Equatable, Sendable {
    public enum Shape: String, Codable, CaseIterable, Sendable { case circle, roundedRectangle }
    public var enabled = true
    public var shape: Shape = .circle
    public var size = 0.24
    public var x = 1.0
    public var y = 1.0
    public var mirrored = true
    public var shadow = true
    public init() {}

    public var isValid: Bool {
        size.isFinite && (0.12...0.45).contains(size) && x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
    }

    /// 返回 Core Image 使用的左下角坐标；尺寸以画布短边为基准，横竖画布共用同一含义。
    public func rect(in canvas: CGSize) -> CGRect {
        let edge = min(canvas.width, canvas.height), margin = edge * 0.035
        let width = edge * size, height = width * (shape == .circle ? 1 : 0.75)
        return CGRect(x: margin + (canvas.width - 2 * margin - width) * x,
                      y: canvas.height - margin - height - (canvas.height - 2 * margin - height) * y,
                      width: width, height: height)
    }
}

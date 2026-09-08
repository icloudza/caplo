import SwiftUI

/// 工作区卡片共享圆角和玻璃细亮边；材质底由各容器提供，不在卡片内重复建立模糊层。
public struct StudioCardModifier: ViewModifier {
    public init() {}
    public func body(content: Content) -> some View {
        content.clipShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.panel, style: .continuous))
            .overlay { CaploGlassBorder(cornerRadius: CaploMetrics.Radius.panel) }
    }
}

public extension View {
    func studioCard() -> some View { modifier(StudioCardModifier()) }
}

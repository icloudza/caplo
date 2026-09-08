import SwiftUI

/// 录制条 / 录制控制条的容器：56 点高透光玻璃面板，细亮边与柔和阴影强调悬浮层次；
/// 空白处按住可拖动整个窗口。
///
/// 阴影与含 AppKit 的模糊视图分开，避免整体栅格化破坏背景采样；保留窗口四周的留白。
public struct FloatingBar<Content: View>: View {
    private let content: Content
    @Environment(\.colorScheme) private var scheme

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        HStack(spacing: CaploMetrics.Spacing.s) { content }
            .padding(.horizontal, 10)
            .frame(height: CaploMetrics.floatingBarHeight)
            .background {
                RoundedRectangle(cornerRadius: CaploMetrics.Radius.floating)
                    .fill(CaploColor.glassShade)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.22), radius: 5, y: 2)
                    .overlay {
                        CaploMaterialBackground(.floating)
                            .clipShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.floating))
                    }
                    .overlay {
                        CaploGlassBorder(cornerRadius: CaploMetrics.Radius.floating)
                    }
                    // 控件之外的区域按住即拖动窗口；控件自身仍优先响应点击。
                    .gesture(WindowDragGesture())
            }
    }
}

/// 浮动条内的竖向分隔。
public struct FloatingBarDivider: View {
    public init() {}
    public var body: some View {
        Rectangle().fill(CaploColor.separator).frame(width: CaploMetrics.hairline, height: 28).accessibilityHidden(true)
    }
}

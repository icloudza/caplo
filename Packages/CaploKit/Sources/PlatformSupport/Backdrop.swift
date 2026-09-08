import AppKit
import SwiftUI

/// 使用所有目标系统均支持的材质后端，集中隔离平台外观差异。
/// 后续可在此评估原生 Liquid Glass，无需修改业务页面。
public struct Backdrop: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

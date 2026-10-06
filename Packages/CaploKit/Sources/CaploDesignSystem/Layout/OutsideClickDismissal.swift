import AppKit
import SwiftUI

public extension View {
    /// 弹窗（`.sheet`）里用：点弹窗外面——父窗口上任意一处——就执行 `action`（通常就是"取消"）。
    ///
    /// 系统表单是窗口模态的，点父窗口只会"咚"一声，用户得去找"取消"按钮（2026-10-06 用户要求能点空白处关闭）。
    /// 这里在表单窗口里放一个零尺寸的探针，表单显示期间挂一个本地事件监视器：父窗口收到鼠标按下就关掉表单，
    /// 并吞掉这一下——不然同一下点击还会落到编辑器里，顺手选中或拖动了底下的东西。
    func onOutsideClick(perform action: @escaping @MainActor () -> Void) -> some View {
        background(OutsideClickProbe(action: action))
    }
}

private struct OutsideClickProbe: NSViewRepresentable {
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.action = action
        return view
    }
    func updateNSView(_ view: ProbeView, context: Context) { view.action = action }
    static func dismantleNSView(_ view: ProbeView, coordinator: ()) { view.stopMonitoring() }

    @MainActor final class ProbeView: NSView {
        var action: (@MainActor () -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                // 本地监视器在主线程回调；只把"要不要吞掉"这个布尔值带出隔离区（NSEvent 不是 Sendable）。
                let swallowed = MainActor.assumeIsolated { () -> Bool in
                    // 只认父窗口上的按下：表单里的点击、弹出菜单、别的窗口都照常处理。
                    // 弹窗自己又开了模态面板（选文件夹、替换确认）时不算：那时点到父窗口只是没点准，不能把弹窗关掉。
                    guard let self, NSApp.modalWindow == nil, let sheet = self.window, sheet.isVisible, sheet.attachedSheet == nil,
                          let parent = sheet.sheetParent, event.window === parent else { return false }
                    self.action?()
                    return true
                }
                return swallowed ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

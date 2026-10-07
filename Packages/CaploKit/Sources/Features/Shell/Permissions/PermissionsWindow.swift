import AppKit
import SwiftUI

/// 权限窗口的打开时机与关窗后的去向。只开一个；再次打开时换内容（场合与高亮行）并置前。
@MainActor
final class PermissionsWindow: NSObject, NSWindowDelegate {
    static let shared = PermissionsWindow()
    static let identifier = "caplo-permissions"

    enum Context {
        /// 启动时屏幕录制未授权：关窗后出录制方式条。
        case launch
        /// 录制或转写前发现缺权限、或从设置页查看：关窗即可。
        case standalone
    }

    private var controller: StudioWindowController?
    private var context = Context.standalone

    /// 只在真正的应用包里拦截：测试进程与离屏预览没有屏幕录制权限，也不该被权限窗口挡住流程。
    static var enforced: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var isVisible: Bool { controller?.window?.isVisible == true }

    func show(_ context: Context, focus: PermissionKind? = nil) {
        self.context = context
        let center = PermissionCenter.shared
        let view = PermissionsView(center: center, continueTitle: context == .launch ? "开始使用" : "完成",
                                   requiresScreen: context == .launch || focus == .screen, focus: focus,
                                   onContinue: { [weak self] in self?.finish() }, onLater: { [weak self] in self?.finish() })
            .ignoresSafeArea()
        if let controller {
            controller.replaceContent(view)
        } else {
            let controller = StudioWindowController(identifier: Self.identifier, title: "权限", content: view,
                                                    sizing: .fixed(PermissionsView.size), chrome: .hiddenTitle)
            WindowRegistry.register(controller)
            controller.window?.delegate = self
            controller.window?.standardWindowButton(.miniaturizeButton)?.isHidden = true
            controller.window?.standardWindowButton(.zoomButton)?.isHidden = true
            controller.window?.collectionBehavior.insert(.fullScreenNone)
            self.controller = controller
        }
        center.startWatching()
        if controller?.window?.isVisible != true { controller?.window?.center() }
        StudioWindows.present(controller?.window)
    }

    /// 主按钮、"稍后"与红色关闭钮都走这里。启动引导到此算走完，之后启动只在屏幕录制缺失时再出现。
    private func finish() {
        if context == .launch { PermissionCenter.onboardingDone = true }
        controller?.window?.orderOut(nil)
        cleanUp()
    }

    func windowWillClose(_ notification: Notification) { cleanUp() }

    private func cleanUp() {
        if context == .launch { PermissionCenter.onboardingDone = true }
        PermissionCenter.shared.stopWatching()
        AppPresence.update()
        let context = self.context
        self.context = .standalone
        // 启动时的权限窗口关掉后回到正常入口；下一轮再显示，避免在关闭回调里改关键窗口。
        if context == .launch { Task { @MainActor in StudioWindows.showRecorder() } }
    }
}

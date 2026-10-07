import AppKit
import ServiceManagement

/// 应用在系统里的存在方式：登录时启动、Dock 图标。
///
/// - 登录时启动走 `SMAppService.mainApp`，开关状态以系统为准（用户可能在"系统设置 → 通用 → 登录项"里关掉），不另存一份；
///   登录启动时不弹录制方式条，只在菜单栏待命。
/// - 隐藏 Dock 图标：平时是 `.accessory`（只有菜单栏图标）；编辑器、项目中心、设置这类要切来切去的窗口开着时临时回到 `.regular`，
///   能在 Dock 与 ⌘Tab 里找到、也有主菜单；它们都关掉后再收回去。录制方式条、录制条这些浮条不算。
@MainActor
enum AppPresence {
    static let hidesDockIconKey = "app.hidesDockIcon"
    /// 需要 Dock 与 ⌘Tab 的窗口。
    static let managedWindows: Set<String> = ["caplo-video-editor", "caplo-project-library", "caplo-settings", "caplo-permissions"]

    static var hidesDockIcon: Bool {
        get { UserDefaults.standard.bool(forKey: hidesDockIconKey) }
        set { UserDefaults.standard.set(newValue, forKey: hidesDockIconKey); update() }
    }

    // MARK: Dock 图标

    private static var observers: [NSObjectProtocol] = []

    /// 启动时调用一次：先按设置定好激活策略，再盯住窗口的打开与关闭。
    static func start() {
        update()
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // 关闭通知发出时窗口还在屏上：放到下一轮再数。
                Task { @MainActor in update() }
            })
        }
    }

    /// 按设置与当前窗口重新决定要不要 Dock 图标。窗口被 `orderOut` 收起不发通知，收起的地方要自己调一次。
    static func update() {
        let needsDock = !hidesDockIcon || NSApp.windows.contains { window in
            guard let id = window.identifier?.rawValue, managedWindows.contains(id) else { return false }
            return window.isVisible || window.isMiniaturized
        }
        let policy: NSApplication.ActivationPolicy = needsDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // 从 .accessory 切回 .regular 时系统不会把窗口带到前面，主菜单也要激活后才出现。
        if policy == .regular, NSApp.keyWindow != nil || NSApp.windows.contains(where: \.isVisible) { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: 登录时启动

    enum LoginItemState: Equatable { case off, on, needsApproval, unavailable }

    /// 未注册时系统可能报 `.notFound` 而不是 `.notRegistered`（实测：从 DMG 拖进"应用程序"的发布包首次打开即如此），
    /// 这时照样可以注册。只有应用确实不在"应用程序"文件夹（例如直接从 DMG 或下载目录运行）才判定为不可用。
    static var loginItemState: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        case .notRegistered, .notFound: isInApplicationsFolder ? .off : .unavailable
        @unknown default: isInApplicationsFolder ? .off : .unavailable
        }
    }

    /// 应用位于 /Applications 或 ~/Applications（含子文件夹）。
    static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return path.hasPrefix("/Applications/") || path.hasPrefix(user + "/")
    }

    /// 打开或关闭登录时启动；失败返回给用户看的原因。
    static func setLaunchesAtLogin(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            // 已经是目标状态时系统也会抛错，以状态为准。
            if (loginItemState == .on || loginItemState == .needsApproval) == enabled { return nil }
            return enabled ? "没能加入登录项：\(error.localizedDescription)" : "没能移出登录项：\(error.localizedDescription)"
        }
    }

    static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// 这次启动是不是登录时由系统拉起的（打开应用的 Apple Event 带"作为登录项启动"标记）。只在启动回调里有效。
    static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

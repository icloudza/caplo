import AppKit
import UserNotifications

/// 后台发现新版本时发系统通知，通知带"查看"按钮；点按钮或点通知本身都拉出更新窗口。
///
/// 通知权限在第一次需要时询问（权限引导窗口里也能提前开）；用户拒绝或系统不允许时返回 false，
/// 由调用方退回直接显示更新窗口（不抢焦点）。只在真正的应用包里使用：测试与离屏预览进程里
/// `UNUserNotificationCenter` 不可用，调用即崩溃。
@MainActor
final class UpdateNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateNotifier()
    nonisolated static let category = "caplo.update"
    nonisolated static let viewAction = "view"
    private static let requestID = "caplo.update.available"

    /// 点"查看"或通知本身时做的事（由 `AppUpdater` 启动后设成拉出更新窗口）。
    /// 应用是被点通知拉起来的：点击可能先于 `AppUpdater` 启动到达，先记下，设好处理后立即补上。
    var onView: (() -> Void)? {
        didSet { if pendingView, let onView { pendingView = false; onView() } }
    }
    private var pendingView = false
    private var started = false

    private func handleView() {
        if let onView { onView() } else { pendingView = true }
    }

    /// 应用即将完成启动时调用（越早越好，应用被点通知拉起时系统才能把点击交给这里）：
    /// 注册带"查看"按钮的通知类别，并接管通知的点击与前台展示。
    func start() {
        guard PermissionsWindow.enforced, !started else { return }
        started = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let view = UNNotificationAction(identifier: Self.viewAction, title: String(localized: "查看"), options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [view], intentIdentifiers: [])])
    }

    /// 发"有新版本"的通知；没有权限（拒绝过、或询问时被拒）返回 false。
    func notify(version: String) async -> Bool {
        guard PermissionsWindow.enforced else { return false }
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
            PermissionCenter.shared.refresh()
        }
        guard status == .authorized || status == .provisional else { return false }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Caplo \(version) 已发布")
        content.body = String(localized: "点“查看”了解更新内容并安装。")
        content.categoryIdentifier = Self.category
        content.sound = .default
        // 同一个标识：再次发现新版本时替换旧通知，通知中心里不会堆一串。
        let request = UNNotificationRequest(identifier: Self.requestID, content: content, trigger: nil)
        do { try await center.add(request) } catch { return false }
        return true
    }

    /// 更新已处理（安装、跳过、稍后）：撤掉还留在通知中心里的那条。
    func withdraw() {
        guard PermissionsWindow.enforced else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.requestID])
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.categoryIdentifier == Self.category,
              response.actionIdentifier == Self.viewAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run { UpdateNotifier.shared.handleView() }
    }

    /// 应用在前台时系统默认不显示横幅：更新提醒照样显示。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

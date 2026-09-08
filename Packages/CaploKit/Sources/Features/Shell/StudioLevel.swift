import AppKit

/// 录制准备与录制中的浮层层级：高于菜单栏与程序坞（`.statusBar`），低于弹出菜单（`.popUpMenu`），
/// 因此覆盖层与录制条压在其他应用的所有窗口之上，而录制条的下拉菜单仍能弹在它之上。
enum StudioLevel {
    /// 区域框选、窗口点选、窗口遮罩。
    static let overlay = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 2)
    /// 录制条、倒计时与录制控制条，位于所有覆盖层之上。
    static let bar = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
}

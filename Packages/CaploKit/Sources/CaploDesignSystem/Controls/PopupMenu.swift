import AppKit
import SwiftUI

/// 自绘按钮弹出的原生菜单条目。录制条与面板里的下拉都走这里：菜单由 `NSMenu` 承担，SwiftUI 重绘不会把它收起；
/// 按钮标签是普通视图，里面子视图的观察更新照常生效（SwiftUI `Menu` 的标签由菜单按钮托管，两者都做不到）。
/// 条目在点击时才构建，菜单里显示的永远是当下的状态。
public enum PopupMenuEntry {
    case item(String, checked: Bool = false, enabled: Bool = true, action: @MainActor () -> Void)
    case separator
    case header(String)
    /// 只读的一行说明（不可点）。
    case text(String)
    case submenu(String, [PopupMenuEntry])
}

/// 记住控件对应的 AppKit 视图，弹菜单时据此定位。
@MainActor
public final class MenuAnchor {
    weak var view: NSView?
    public init() {}

    /// 从控件正下方弹出（贴屏幕底时 AppKit 自动改到上方）；`appearance` 指定菜单外观（录制条一律深色）。
    public func popUp(_ entries: [PopupMenuEntry], appearance: NSAppearance.Name? = nil) {
        guard let view else { return }
        let menu = Self.makeMenu(entries)
        if let appearance { menu.appearance = NSAppearance(named: appearance) }
        menu.minimumWidth = view.bounds.width
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4), in: view)
    }

    /// 条目 → NSMenu；动作对象挂在菜单项的 representedObject 上，随菜单项存活。
    public static func makeMenu(_ entries: [PopupMenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .header(let title):
                menu.addItem(NSMenuItem.sectionHeader(title: title))
            case .text(let title):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case .submenu(let title, let children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = makeMenu(children)
                menu.addItem(item)
            case .item(let title, let checked, let enabled, let action):
                let target = MenuTarget(action)
                let item = NSMenuItem(title: title, action: #selector(MenuTarget.fire), keyEquivalent: "")
                item.target = target
                item.representedObject = target
                item.state = checked ? .on : .off
                item.isEnabled = enabled
                menu.addItem(item)
            }
        }
        return menu
    }
}

@MainActor
final class MenuTarget: NSObject {
    private let run: @MainActor () -> Void
    init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    @objc func fire() { run() }
}

/// 零尺寸、不响应点击的锚点视图，铺在按钮底下，尺寸即按钮尺寸。
struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor
    func makeNSView(context: Context) -> AnchorView { let view = AnchorView(); anchor.view = view; return view }
    func updateNSView(_ view: AnchorView, context: Context) { anchor.view = view }

    final class AnchorView: NSView {
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// 弹菜单按钮的样式：按下变淡；键盘焦点用强调色描边（系统焦点环与圆角底板不贴合）。
struct PopupButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyleBody(configuration: configuration) }

    private struct StyleBody: View {
        let configuration: Configuration
        @FocusState private var focused: Bool
        var body: some View {
            configuration.label
                .overlay {
                    if focused { RoundedRectangle(cornerRadius: CaploMetrics.Radius.control).strokeBorder(CaploColor.accent.opacity(0.9), lineWidth: 2) }
                }
                .opacity(configuration.isPressed ? 0.8 : 1)
                .focused($focused)
                .focusEffectDisabled()
        }
    }
}

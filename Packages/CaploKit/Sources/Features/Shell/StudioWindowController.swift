import AppKit
import SwiftUI
import CaploDesignSystem

/// 统一的窗口构造：尺寸策略与外观显式声明，宿主视图始终放在普通容器视图内。
///
/// `NSHostingView` 直接充当 `contentView` 时，其约束更新会驱动窗口尺寸极值并在同一轮里
/// 失效变换、再次请求约束更新，最终 AppKit 抛出 "more Update Constraints passes than there
/// are views" 异常；容器视图隔断了这条回路。固定尺寸窗口同时钳定内容尺寸上下限。
@MainActor
public final class StudioWindowController: NSWindowController {
    public enum Sizing {
        case fixed(CGSize)
        case resizable(min: CGSize, initial: CGSize)

        var initial: CGSize {
            switch self { case .fixed(let size): size; case .resizable(_, let initial): initial }
        }
    }

    public enum Chrome {
        /// 标准标题栏。
        case standard
        /// 隐藏标题文字、标题栏透明，内容位于标题栏之下；保留原生红黄绿。
        case hiddenTitle
        /// 内容延伸到标题栏之下，标题栏取统一工具栏高度（52 点），红黄绿垂直居中；
        /// 内容顶部由业务视图绘制顶栏并为红黄绿预留左侧空间。
        case unifiedTitle
        /// 无标题栏浮动面板，用于录制条与录制控制；`activating` 为 false 时点击不激活应用。
        case borderlessPanel(activating: Bool)
    }

    public let identifier: String
    private let sizing: Sizing
    private let chrome: Chrome

    public init<V: View>(identifier: String, title: String, content: V, sizing: Sizing, chrome: Chrome = .standard) {
        self.identifier = identifier
        self.sizing = sizing
        self.chrome = chrome
        let size = sizing.initial
        var style: NSWindow.StyleMask
        var panelActivating: Bool? = nil
        switch chrome {
        case .standard: style = [.titled, .closable, .miniaturizable]
        // 隐藏标题的窗口把玻璃铺到标题栏之下，红黄绿直接落在内容上；否则透明标题栏会露出后面的桌面。
        case .hiddenTitle: style = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        case .unifiedTitle: style = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        case .borderlessPanel(let activating):
            style = activating ? [.borderless] : [.borderless, .nonactivatingPanel]
            panelActivating = activating
        }
        if case .resizable = sizing { style.insert(.resizable) }

        let window: NSWindow
        if let activating = panelActivating {
            let panel = activating
                ? KeyablePanel(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
                : NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            // 与覆盖层同属置顶层级，压在其他应用所有窗口与菜单栏之上。
            panel.level = StudioLevel.bar
            panel.hidesOnDeactivate = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            // 悬浮材质的描边与阴影由内容统一绘制；透明宿主不再叠加系统窗口阴影。
            panel.hasShadow = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window = panel
        } else {
            window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
            // 背景只由内容根部的一层玻璃采样；宿主透空，避免实色窗口底挡住桌面透光。
            window.backgroundColor = .clear
            window.isOpaque = false
            window.titlebarAppearsTransparent = true
        }
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        if case .hiddenTitle = chrome {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
        }
        if case .unifiedTitle = chrome {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            // 统一标题栏靠空工具栏撑出 52 点高度；macOS 15 起系统不再画基线分隔，无需再关。
            let toolbar = NSToolbar(identifier: "caplo-unified-\(identifier)")
            window.toolbar = toolbar
        }

        let host = TransparentStudioHostingView(rootView: content)
        host.identifier = NSUserInterfaceItemIdentifier("caplo.window.content-host")
        if case .unifiedTitle = chrome {
            // 统一标题栏之下由内容自己为红黄绿留位；不把标题栏当作安全区，否则 SwiftUI 会让滚动视图
            // 伸到顶栏后面、内容从顶栏底下滚出来。
            host.safeAreaRegions = []
        }
        host.wantsLayer = true
        host.layer?.isOpaque = false
        host.layer?.backgroundColor = NSColor.clear.cgColor
        switch sizing {
        case .fixed: host.sizingOptions = []
        case .resizable: break
        }
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.identifier = NSUserInterfaceItemIdentifier("caplo.window.content-container")
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container

        switch sizing {
        case .fixed(let size):
            window.contentMinSize = size
            window.contentMaxSize = size
        case .resizable(let min, _):
            window.contentMinSize = min
        }
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("StudioWindowController 不支持从 nib 创建") }

    /// 固定尺寸窗口换一个固定尺寸（例如更新窗口在状态小窗与说明大窗之间切换），顶边与水平中心不动。
    public func setFixedContentSize(_ size: CGSize, animate: Bool) {
        guard case .fixed = sizing, let window else { return }
        guard window.contentRect(forFrameRect: window.frame).size != size else { return }
        window.contentMinSize = size
        window.contentMaxSize = size
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        frame.origin = CGPoint(x: window.frame.midX - frame.width / 2, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }

    /// 替换内容视图，保持窗口与尺寸策略不变。
    public func replaceContent<V: View>(_ content: V) {
        guard let window else { return }
        // 编辑器关闭时清空内容；再次打开也经相同透明容器恢复，不能退回直接挂 NSHostingView。
        let container = window.contentView ?? NSView(frame: CGRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size))
        container.identifier = NSUserInterfaceItemIdentifier("caplo.window.content-container")
        container.subviews.forEach { $0.removeFromSuperview() }
        let host = TransparentStudioHostingView(rootView: content)
        host.identifier = NSUserInterfaceItemIdentifier("caplo.window.content-host")
        if case .unifiedTitle = chrome {
            // 统一标题栏之下由内容自己为红黄绿留位；不把标题栏当作安全区，否则 SwiftUI 会让滚动视图
            // 伸到顶栏后面、内容从顶栏底下滚出来。
            host.safeAreaRegions = []
        }
        host.wantsLayer = true
        host.layer?.isOpaque = false
        host.layer?.backgroundColor = NSColor.clear.cgColor
        if case .fixed = sizing { host.sizingOptions = [] }
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        if window.contentView !== container { window.contentView = container }
    }
}

/// SwiftUI 内容的空白与窗口边缘保持透空；玻璃与辅助功能回退由共享材质绘制。
private final class TransparentStudioHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

/// 无标题栏但可成为 key 的面板：录制条需要键盘操作与菜单弹出。
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 持有应用中所有 `StudioWindowController`，按标识符保证唯一实例。
@MainActor
public enum WindowRegistry {
    private static var controllers: [String: StudioWindowController] = [:]

    public static func register(_ controller: StudioWindowController) {
        controllers[controller.identifier] = controller
    }

    public static func controller(for identifier: String) -> StudioWindowController? {
        controllers[identifier]
    }

    public static func remove(_ identifier: String) {
        controllers[identifier]?.close()
        controllers[identifier] = nil
    }

    public static var all: [StudioWindowController] { Array(controllers.values) }
}

import AppKit
import SwiftUI

/// 自绘悬停提示：鼠标停 0.45 秒后在控件下方浮出一条深色小标签，移开即消失。
/// 不依赖系统 tooltip（在自定义窗口与宿主视图混排时不可靠），样式与录制条同一套玻璃语言。
public extension View {
    func hoverTip(_ text: String) -> some View { modifier(HoverTipModifier(text: text)) }
}

private struct HoverTipModifier: ViewModifier {
    let text: String
    @State private var shown = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .background(HoverTipAnchor(text: text, shown: shown))
            .onHover { inside in
                pending?.cancel()
                if inside {
                    pending = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        if !Task.isCancelled { shown = true }
                    }
                } else { shown = false }
            }
            .onDisappear { pending?.cancel(); shown = false }
    }
}

/// 零尺寸的锚点视图：知道自己在屏幕上的位置，负责把共享的提示窗放到控件正下方。
private struct HoverTipAnchor: NSViewRepresentable {
    let text: String
    let shown: Bool

    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {
        view.text = text
        view.shown = shown
        view.sync()
    }
    static func dismantleNSView(_ view: AnchorView, coordinator: ()) { if HoverTipWindow.shared.owner === view { HoverTipWindow.shared.hide() } }

    @MainActor final class AnchorView: NSView {
        var text = ""
        var shown = false
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func sync() {
            if shown, let window, superview != nil {
                let rect = window.convertToScreen(convert(bounds, to: nil))
                HoverTipWindow.shared.show(text, below: rect, owner: self)
            } else if HoverTipWindow.shared.owner === self {
                HoverTipWindow.shared.hide()
            }
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil, HoverTipWindow.shared.owner === self { HoverTipWindow.shared.hide() }
        }
    }
}

/// 整个应用共用一个提示窗：无边框、不激活、点击穿透，浮在所属窗口之上。
@MainActor
public final class HoverTipWindow {
    public static let shared = HoverTipWindow()
    private var panel: NSPanel?
    private var host: NSHostingView<HoverTipLabel>?
    weak var owner: NSView?
    public private(set) var text: String?

    func show(_ text: String, below rect: NSRect, owner: NSView) {
        self.owner = owner; self.text = text
        let panel = self.panel ?? makePanel()
        let label = HoverTipLabel(text: text)
        if let host { host.rootView = label } else {
            let host = NSHostingView(rootView: label)
            panel.contentView = host
            self.host = host
        }
        host?.layoutSubtreeIfNeeded()
        let size = host?.fittingSize ?? .zero
        // 控件正下方 6 点；贴近屏幕底部时改到上方；左右钳在屏幕可见区域内。
        let screen = owner.window?.screen ?? NSScreen.main
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - 6 - size.height)
        if let visible = screen?.visibleFrame {
            if origin.y < visible.minY { origin.y = rect.maxY + 6 }
            origin.x = min(max(visible.minX + 4, origin.x), visible.maxX - size.width - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFront(nil)
    }

    public func hide() {
        panel?.orderOut(nil)
        owner = nil; text = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }
}

/// 提示标签：11 点白字、深色实底、6 点圆角。
public struct HoverTipLabel: View {
    let text: String
    public init(text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .font(CaploFont.caption)
            .foregroundStyle(CaploColor.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(CaploColor.surfaceOpaqueRaised.opacity(0.96), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(CaploColor.glassEdge.opacity(0.6)))
            .fixedSize()
            .preferredColorScheme(.dark)
    }
}

import AppKit
import SwiftUI
import Testing
@testable import CaploDesignSystem

/// 自绘悬停提示：提示窗浮在控件正下方、不激活、点击穿透；隐藏后不再引用锚点。
@MainActor
struct HoverTipTests {
    @Test func tipWindowAppearsBelowAnchorAndHides() throws {
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let anchor = NSView(frame: CGRect(x: 100, y: 120, width: 30, height: 30))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        HoverTipWindow.shared.show("在播放头分割 ⌘B", below: rect, owner: anchor)
        let panel = try #require(NSApp.windows.compactMap { $0 as? NSPanel }.first { $0.contentView is NSHostingView<HoverTipLabel> })
        #expect(panel.isVisible && panel.ignoresMouseEvents && !panel.isOpaque && panel.level == NSWindow.Level.floating)
        #expect(HoverTipWindow.shared.text == "在播放头分割 ⌘B")
        // 正下方 6 点，水平居中。
        #expect(abs(panel.frame.maxY - (rect.minY - 6)) < 0.5)
        #expect(abs(panel.frame.midX - rect.midX) <= 1)
        #expect(panel.frame.width > 40 && panel.frame.height >= 18)
        HoverTipWindow.shared.hide()
        #expect(!panel.isVisible && HoverTipWindow.shared.owner == nil && HoverTipWindow.shared.text == nil)
    }
}

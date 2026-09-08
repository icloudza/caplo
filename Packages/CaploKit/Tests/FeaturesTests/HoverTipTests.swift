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

    /// 说明性长文本按 260 点宽换行，提示窗高度随行数增长，文字不会溢出底板。
    @Test func longTipWrapsAndTheWindowGrowsToFit() throws {
        let window = NSWindow(contentRect: CGRect(x: 200, y: 300, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let anchor = NSView(frame: CGRect(x: 100, y: 120, width: 16, height: 16))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let long = "按点击推近，提前读取鼠标轨迹并平滑跟随。不点鼠标的讲解也能聚焦：在时间线的镜头行拖出一段范围，镜头会推近到指针所在并跟着走。相邻镜头间隔小于合并间隔时直接平移过去，不拉远。"
        HoverTipWindow.shared.show(long, below: rect, owner: anchor)
        defer { HoverTipWindow.shared.hide() }
        let panel = try #require(NSApp.windows.compactMap { $0 as? NSPanel }.first { $0.contentView is NSHostingView<HoverTipLabel> })
        let host = try #require(panel.contentView as? NSHostingView<HoverTipLabel>)
        // 宽度被限制在 260 加内边距以内，高度至少三行；宿主视图的理想尺寸与提示窗一致（没有被裁掉的部分）。
        #expect(panel.frame.width <= 290 && panel.frame.width > 200)
        #expect(panel.frame.height >= 50)
        #expect(abs(host.fittingSize.height - panel.frame.height) < 0.5 && abs(host.fittingSize.width - panel.frame.width) < 0.5)
        // 短提示仍是单行。
        HoverTipWindow.shared.show("在播放头分割 ⌘B", below: rect, owner: anchor)
        #expect(panel.frame.height < 30)
    }
}

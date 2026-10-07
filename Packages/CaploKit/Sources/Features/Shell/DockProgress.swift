import AppKit
import SwiftUI

/// Dock 图标底部的进度条（与访达拷贝、Safari 下载同一种样式）：导出期间显示，结束后恢复原图标。
///
/// Dock 图标重画要经过 Dock 进程，代价不小：进度变化不足 1% 不重画，一次导出最多刷新约一百次。
/// 隐藏 Dock 图标的设置下，编辑器打开时应用本来就回到了 Dock（见 `AppPresence`），进度条照常可见。
@MainActor
enum DockProgress {
    private static var view: DockProgressView?
    private static var shown = -1.0

    /// `fraction` 取 0…1。第一次调用时换上进度视图。
    static func update(_ fraction: Double) {
        let tile = NSApp.dockTile
        let value = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        if view == nil {
            let progress = DockProgressView(frame: CGRect(origin: .zero, size: tile.size))
            tile.contentView = progress
            view = progress
        }
        guard abs(value - shown) >= 0.01 || (value >= 1 && shown < 1) else { return }
        shown = value
        view?.fraction = value
        tile.display()
    }

    /// 恢复原图标（导出完成、取消或失败都走这里）。
    static func hide() {
        guard view != nil else { return }
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
        view = nil
        shown = -1
    }
}

/// 应用图标 + 底部圆角进度条：深色半透明轨道、白色填充，浅色与深色 Dock 上都清楚。
final class DockProgressView: NSView {
    var fraction = 0.0
    var icon: NSImage = NSApp.applicationIconImage

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds)
        let height = bounds.height * 0.11
        let track = NSRect(x: bounds.width * 0.1, y: bounds.height * 0.07, width: bounds.width * 0.8, height: height)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2).fill()
        let inner = track.insetBy(dx: height * 0.2, dy: height * 0.2)
        // 刚开始时也留一个圆点，让人看出"已经开始"而不是空轨道。
        let width = max(inner.height, inner.width * min(max(fraction, 0), 1))
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: width, height: inner.height),
                     xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
    }
}

/// 离屏预览：按给定进度画 Dock 图标（预览进程没有应用图标时用传入的图）。
public struct DockProgressPreview: NSViewRepresentable {
    let fraction: Double
    let icon: NSImage?
    public init(fraction: Double, icon: NSImage? = nil) { self.fraction = fraction; self.icon = icon }
    public func makeNSView(context: Context) -> NSView {
        let view = DockProgressView(frame: CGRect(x: 0, y: 0, width: 128, height: 128))
        view.fraction = fraction
        if let icon { view.icon = icon }
        return view
    }
    public func updateNSView(_ nsView: NSView, context: Context) {}
}

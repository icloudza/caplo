import AppKit
import SwiftUI

/// 品牌图形资源。菜单栏图标为单色模板图，由系统按菜单栏明暗与强调色着色，不放文字。
public enum CaploBrand {
    /// 菜单栏常态图标（18×18 pt）：粗环字母 C 包着录制点，与应用图标同一图形（2026-10-07 定稿，源稿见 Docs/图标方案/定稿）。
    public static var menuBarIcon: Image { templateImage("MenuBarIcon") }

    /// 菜单栏录制中图标：不另加角标，就让 C 中间那颗录制点变红（`dotOpacity` 由调用方做呼吸）。
    /// 红点没法放进单色模板图，所以整张图在绘制时现画：环用 `labelColor`，绘制回调里取到的是状态栏按钮
    /// 跟随菜单栏明暗的外观（不是应用强制的深色），浅色、深色菜单栏下都与常态图标同色；几何与定稿模板图一致
    /// （圆心 9,9，半径 6.3，线宽 3，右侧开口 ±40°，中心点半径 2.2）。
    public static func menuBarRecordingImage(dotOpacity: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let ring = NSBezierPath()
            ring.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 6.3, startAngle: 40, endAngle: 320)
            ring.lineWidth = 3
            ring.lineCapStyle = .round
            NSColor.labelColor.setStroke()
            ring.stroke()
            // 偏柔的红（接近窗口关闭按钮），不用纯红，菜单栏里不扎眼。
            NSColor(srgbRed: 1, green: 0.33, blue: 0.3, alpha: dotOpacity).setFill()
            NSBezierPath(ovalIn: NSRect(x: 9 - 2.2, y: 9 - 2.2, width: 4.4, height: 4.4)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Caplo · 录制中"
        return image
    }

    /// Xcode 构建把资源目录编译进 Assets.car；`swift build`（离屏预览、窗口回归）只拷贝原始目录，
    /// 此时直接读取 imageset 里的 PNG，保证两种构建下图标都可见。
    private static func templateImage(_ name: String) -> Image {
        if let image = Bundle.module.image(forResource: name) {
            image.isTemplate = true
            return Image(nsImage: image).renderingMode(.template)
        }
        if let url = Bundle.module.url(forResource: "\(name)@2x", withExtension: "png", subdirectory: "Brand.xcassets/\(name).imageset"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return Image(nsImage: image).renderingMode(.template)
        }
        return Image(systemName: "record.circle")
    }
}

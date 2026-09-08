import AppKit
import SwiftUI

/// 品牌图形资源。菜单栏图标为单色模板图，由系统按菜单栏明暗与强调色着色，不放文字。
public enum CaploBrand {
    /// 菜单栏常态图标（18×18 pt）。
    public static var menuBarIcon: Image { templateImage("MenuBarIcon") }

    /// 菜单栏录制中图标：丝带右下角带实心圆点。
    public static var menuBarRecordingIcon: Image { templateImage("MenuBarIconRecording") }

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

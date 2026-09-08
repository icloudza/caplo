import AppKit
import SwiftUI

/// 深色玻璃的语义颜色：薄中性表面透出环境，不把背景颜色固化到材质中。产品只有一套深色主题。
/// SwiftUI 与 AppKit 共用同一份 NSColor，避免原生时间线和属性面板出现色差。
public enum CaploColor {
    public static let surfaceWindow = Color(nsColor: CaploNSColor.surfaceWindow)
    public static let surfacePanel = Color(nsColor: CaploNSColor.surfacePanel)
    public static let surfaceRaised = Color(nsColor: CaploNSColor.surfaceRaised)
    public static let surfaceCanvasWell = Color(nsColor: CaploNSColor.surfaceCanvasWell)
    public static let surfaceOpaqueWindow = Color(nsColor: CaploNSColor.surfaceOpaqueWindow)
    public static let surfaceOpaquePanel = Color(nsColor: CaploNSColor.surfaceOpaquePanel)
    public static let surfaceOpaqueRaised = Color(nsColor: CaploNSColor.surfaceOpaqueRaised)
    public static let surfaceOpaqueCanvas = Color(nsColor: CaploNSColor.surfaceOpaqueCanvas)
    public static let separator = Color(nsColor: CaploNSColor.separator)
    public static let textPrimary = Color(nsColor: CaploNSColor.textPrimary)
    public static let textSecondary = Color(nsColor: CaploNSColor.textSecondary)
    public static let textTertiary = Color(nsColor: CaploNSColor.textTertiary)
    public static let controlOn = Color(nsColor: CaploNSColor.controlOn)
    public static let primaryButtonFill = Color(nsColor: CaploNSColor.primaryButtonFill)
    public static let primaryButtonText = Color(nsColor: CaploNSColor.primaryButtonText)
    public static let accent = Color(nsColor: CaploNSColor.accent)
    public static let accentFill = Color(nsColor: CaploNSColor.accentFill)
    public static let accentSoft = Color(nsColor: CaploNSColor.accentSoft)
    public static let zoom = Color(nsColor: CaploNSColor.zoom)
    public static let record = Color(nsColor: CaploNSColor.record)
    /// 正在采集 / 试听的活动色（麦克风音波）。
    public static let live = Color(nsColor: CaploNSColor.live)
    public static let recordFill = Color(nsColor: CaploNSColor.recordFill)
    public static let audio = Color(nsColor: CaploNSColor.audio)
    public static let warning = Color(nsColor: CaploNSColor.warning)
    public static let glassDensity = Color(nsColor: CaploNSColor.glassDensity)
    public static let glassEdge = Color(nsColor: CaploNSColor.glassEdge)
    public static let glassSheen = Color(nsColor: CaploNSColor.glassSheen)
    public static let glassShade = Color(nsColor: CaploNSColor.glassShade)
    public static let glassAmbient = Color(nsColor: CaploNSColor.glassAmbient)
}

/// 中性颜色表只维护一次；普通层明确带 alpha，辅助功能回退另用不透明颜色，禁止互相替代。
/// 表面四档按明度分层（窗口 6% → 面板 3% 叠加 → 控件 7.5%），分隔线比控件暗，靠层差而不是描边成形；
/// 文字三档 92% / 66% / 45% 拉开层级。
public enum CaploNSColor {
    public static let surfaceWindow = token("surfaceWindow", 0xFFFFFF, alpha: 0.06)
    public static let surfacePanel = token("surfacePanel", 0xFFFFFF, alpha: 0.03)
    public static let surfaceRaised = token("surfaceRaised", 0xFFFFFF, alpha: 0.075)
    public static let surfaceCanvasWell = token("surfaceCanvasWell", 0x000000, alpha: 0.14)
    public static let surfaceOpaqueWindow = token("surfaceOpaqueWindow", 0x232323)
    public static let surfaceOpaquePanel = token("surfaceOpaquePanel", 0x2B2B2B)
    public static let surfaceOpaqueRaised = token("surfaceOpaqueRaised", 0x383838)
    public static let surfaceOpaqueCanvas = token("surfaceOpaqueCanvas", 0x1D1D1D)
    public static let separator = token("separator", 0xFFFFFF,
                                       alpha: 0.08, highContrastAlpha: 0.46)
    public static let textPrimary = token("textPrimary", 0xF7F7F7)
    public static let textSecondary = token("textSecondary", 0xFFFFFF,
                                           alpha: 0.66, highContrastAlpha: 1)
    public static let textTertiary = token("textTertiary", 0xFFFFFF,
                                          alpha: 0.45, highContrastAlpha: 0.88)
    /// 强调色服务动作与轨道识别，不参与窗口玻璃染色。浅字与实心按钮分别定义对比度。
    public static let controlOn = token("controlOn", 0x80DFB8, alpha: 0.80)
    /// 2026-09-09 定论：界面不再有"主题色"。强调色是冷白，选中态与主按钮靠明度而不是色相成形，
    /// 彩色只留给录制红、开关绿和各轨道识别色（Final Cut / Screen Studio 的路子）。
    public static let primaryButtonFill = token("primaryButtonFill", 0xF2F1F6)
    public static let primaryButtonText = token("primaryButtonText", 0x1C1B22)
    public static let accent = token("accent", 0xE8E6EE)
    public static let accentFill = token("accentFill", 0xF2F1F6)
    public static let accentSoft = token("accentSoft", 0xE8E6EE, alpha: 0.18)
    public static let zoom = token("zoom", 0xACCFFF)
    public static let record = token("record", 0xFF858B)
    public static let live = token("live", 0x5CE07A)
    public static let recordFill = token("recordFill", 0xC93649)
    public static let audio = token("audio", 0x98ECD0)
    public static let warning = token("warning", 0xFFD08A)
    /// 背景只保留模糊环境色，避免编辑文字与桌面内容重叠；中性黑，绝不染成蓝灰。
    /// 密度要足够压住桌面内容的轮廓（参照系统侧栏材质），只让环境色透过来。
    public static let glassDensity = token("glassDensity", 0x000000, alpha: 0.66)
    public static let glassEdge = token("glassEdge", 0xFFFFFF,
                                       alpha: 0.25, highContrastAlpha: 0.68)
    public static let glassSheen = token("glassSheen", 0xFFFFFF, alpha: 0.035)
    public static let glassShade = token("glassShade", 0x000000, alpha: 0.055)
    public static let glassAmbient = token("glassAmbient", 0xFFFFFF, alpha: 0.018)

    /// 产品固定为深色玻璃，令牌不再区分浅色 / 深色外观；只有辅助功能"增强对比度"会改变透明度。
    private static func token(_ name: String, _ hex: UInt32, alpha: CGFloat = 1, highContrastAlpha: CGFloat? = nil) -> NSColor {
        NSColor(name: NSColor.Name("caplo.\(name)")) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            let isHighContrast = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
            return NSColor(hex: hex, alpha: isHighContrast ? (highContrastAlpha ?? alpha) : alpha)
        }
    }
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// 尺寸与形状令牌。业务视图只引用这里的常量；时间线几何集中在各自的 Metrics。
public enum CaploMetrics {
    public enum Radius {
        public static let control: CGFloat = 6
        public static let card: CGFloat = 10
        public static let panel: CGFloat = 12
        public static let floating: CGFloat = 14
    }
    public enum ControlHeight {
        /// 小按钮与 chips。
        public static let small: CGFloat = 24
        /// 标准按钮与下拉。
        public static let medium: CGFloat = 28
        /// 主要动作。
        public static let large: CGFloat = 32
    }
    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
    }
    public enum Slider {
        public static let track: CGFloat = 3
        public static let thumb: CGFloat = 14
        public static let hitHeight: CGFloat = 22
    }
    public enum Icon {
        public static let control: CGFloat = 16
        public static let rail: CGFloat = 20
    }
    public enum Track {
        public static let clip: CGFloat = 56
        public static let zoom: CGFloat = 32
        public static let audio: CGFloat = 40
        public static let headWidth: CGFloat = 120
    }
    /// 编辑器左侧图标栏宽度。
    public static let railWidth: CGFloat = 48
    /// 属性面板宽度。
    public static let panelWidth: CGFloat = 300
    /// 顶栏与时间线工具栏高度。
    public static let toolbarHeight: CGFloat = 44
    /// 编辑器顶栏高度：与统一标题栏等高，原生红黄绿垂直居中于其中。
    public static let titleBarHeight: CGFloat = 52
    /// 隐藏标题的固定尺寸窗口（方式选择、设置）：内容延伸到 28 点系统标题栏之下，首行与红黄绿同高。
    public static let compactTitleBarHeight: CGFloat = 28
    /// 顶栏左侧为红黄绿预留的宽度。
    public static let trafficLightsInset: CGFloat = 78
    /// 录制条高度。
    public static let floatingBarHeight: CGFloat = 56
    /// 承载浮动条的透明面板在条四周的留白；面板尺寸与贴底位置都以此为准。
    public static let floatingBarInset: CGFloat = 12
    /// 1 点分隔线。
    public static let hairline: CGFloat = 1
}

/// 字体层级。
public enum CaploFont {
    /// 窗口标题 / 面板标题。
    public static let panelTitle = Font.system(size: 15, weight: .semibold)
    /// 分区标题，配合 `textSecondary`。
    public static let sectionTitle = Font.system(size: 12, weight: .medium)
    /// 正文与控件文字。
    public static let body = Font.system(size: 13)
    public static let bodyMedium = Font.system(size: 13, weight: .medium)
    /// 参数数值，等宽数字。
    public static let value = Font.system(size: 12).monospacedDigit()
    /// 说明与空态。
    public static let caption = Font.system(size: 11)
    /// 面板里的辅助说明文字，比 caption 再小一号。
    public static let footnote = Font.system(size: 10)
    /// 大号计时数字。
    public static let timer = Font.system(size: 14, weight: .medium, design: .monospaced)
}

/// 动效时长；系统"减少动态效果"开启时调用方应传 `nil` 动画。
public enum CaploMotion {
    public static let hover: Double = 0.12
    public static let press: Double = 0.08
    public static let panel: Double = 0.16

    public static func animation(_ duration: Double, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: duration)
    }
}

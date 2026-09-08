import AppKit
import CaploDesignSystem

/// 原生编辑区共用的透明玻璃底图：主窗口负责背景模糊，此处只叠加中性明暗，不采样视频。
@MainActor
enum EditorMaterialDrawing {
    private static var cachedColors: [CGColor] = []
    private static var cachedGradient: CGGradient?

    static func usesOpaqueSurface(appearance: NSAppearance, opaqueOverride: Bool? = nil) -> Bool {
        // 高对比名称只能用于 bestMatch，不能据此构造 NSAppearance；审核环境通过显式选项注入意图。
        // 实际窗口仍默认读取系统设置，并兼容来自 NSVisualEffectView 的 Vibrant 有效外观。
        if let opaqueOverride { return opaqueOverride }
        let contrastNames: [NSAppearance.Name] = [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                                                 .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark]
        let match = appearance.bestMatch(from: contrastNames + [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
        return NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            || match.map(contrastNames.contains) == true
    }

    static func surface(_ normal: NSColor, opaque: NSColor, appearance: NSAppearance, opaqueOverride: Bool? = nil) -> NSColor {
        usesOpaqueSurface(appearance: appearance, opaqueOverride: opaqueOverride) ? opaque : normal
    }

    static func observeChanges(_ change: @escaping @MainActor @Sendable () -> Void) -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { change() }
        }
    }

    static func stopObserving(_ observer: inout NSObjectProtocol?) {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    static func color(_ color: NSColor, appearance: NSAppearance) -> CGColor {
        var resolved = NSColor.clear.cgColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = (color.usingColorSpace(.sRGB) ?? color).cgColor
        }
        return resolved
    }

    static func gradientColors(appearance: NSAppearance) -> [CGColor] {
        // 高密度时间线只叠中性暗层；方向亮边由轮廓提供，不能把整面刷成白雾。
        [color(CaploNSColor.glassShade.withAlphaComponent(0.01), appearance: appearance),
         color(CaploNSColor.glassShade.withAlphaComponent(0.045), appearance: appearance)]
    }

    static func drawPanel(in rect: CGRect, appearance: NSAppearance, context: CGContext, flipped: Bool,
                          opaqueOverride: Bool? = nil, clearsBacking: Bool = true) {
        guard rect.size.width > 0, rect.size.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        // 只有独立位图由调用方拥有全部像素，才允许清缓存；NSView.draw 可能参与父树的
        // cacheDisplay 合成，清理会擦掉已画好的环境。非 opaque 原生视图由 AppKit 管理脏区。
        if clearsBacking { context.clear(rect) }
        let opaque = usesOpaqueSurface(appearance: appearance, opaqueOverride: opaqueOverride)
        context.setFillColor(color(opaque ? CaploNSColor.surfaceOpaquePanel : CaploNSColor.surfaceCanvasWell, appearance: appearance))
        context.fill(rect)
        guard !opaque else { return }
        let colors = gradientColors(appearance: appearance)
        if colors != cachedColors {
            cachedColors = colors
            cachedGradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: colors as CFArray, locations: [0, 1])
        }
        guard let gradient = cachedGradient else { return }
        context.clip(to: rect)
        let top = flipped ? rect.minY : rect.maxY, bottom = flipped ? rect.maxY : rect.minY
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: top), end: CGPoint(x: rect.maxX, y: bottom), options: [])
    }
}

import AppKit
import SwiftUI

/// 主窗口与悬浮条各采样一层背景；内部面板只提供轻量明暗差，避免多层模糊抹掉环境细节。
public enum CaploMaterialKind: Sendable {
    case window, panel, raised, floating, canvas

    var tint: Color {
        switch self {
        case .window, .floating: CaploColor.surfaceWindow
        case .panel: CaploColor.surfacePanel
        case .raised: CaploColor.surfaceRaised
        case .canvas: CaploColor.surfaceCanvasWell
        }
    }

    var opaqueTint: Color {
        switch self {
        case .window, .floating: CaploColor.surfaceOpaqueWindow
        case .panel: CaploColor.surfaceOpaquePanel
        case .raised: CaploColor.surfaceOpaqueRaised
        case .canvas: CaploColor.surfaceOpaqueCanvas
        }
    }

    var samplesBackdrop: Bool { self == .window || self == .floating }
}

/// 已审核玻璃的原生表达：背景透光、薄中性填充与方向性高光，文字不随材质降低透明度。
/// 只用 macOS 15 起共有的公开合成 API；系统控制模糊核，不把 HTML 的 16px 冒充原生可配置参数。
public struct CaploMaterialBackground: View {
    private let kind: CaploMaterialKind
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.caploMaterialAccessibilityOverride) private var accessibilityOverride
    @Environment(\.caploMaterialWithinWindowPreview) private var withinWindowPreview

    public init(_ kind: CaploMaterialKind = .panel) { self.kind = kind }

    public var body: some View {
        ZStack {
            if opaqueSurface {
                kind.opaqueTint
            } else {
                if kind.samplesBackdrop {
                    MaterialBackdrop(floating: kind == .floating, withinWindow: withinWindowPreview)
                }
                if kind.samplesBackdrop {
                    // 完整保留原生模糊，再以中性暗层控制透底；不能降低整个效果视图 alpha，
                    // 否则未经模糊的底层文字会直接透入，破坏编辑器的可读性。
                    CaploColor.glassDensity
                }
                kind.tint
                // 光泽集中在主表面；内层控件不反复铺渐变，避免逐层积累成白色雾面。
                if kind.samplesBackdrop {
                    LinearGradient(colors: [CaploColor.glassSheen, .clear, CaploColor.glassShade],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        }
        .ignoresSafeArea(edges: kind == .window ? .all : [])
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var opaqueSurface: Bool {
        let reduced = accessibilityOverride?.reduceTransparency ?? reduceTransparency
        let highContrast = accessibilityOverride?.highContrast ?? (contrast == .increased)
        return reduced || highContrast
    }
}

private struct MaterialBackdrop: NSViewRepresentable {
    let floating: Bool
    let withinWindow: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PassiveBackdrop()
        view.identifier = NSUserInterfaceItemIdentifier("caplo.material.backdrop")
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { configure(nsView) }

    private func configure(_ view: NSVisualEffectView) {
        // 按语义选用窗口 / HUD 材质。中性深色只为浅字提供底部对比，不施加固定蓝灰染色。
        view.material = floating ? .hudWindow : .underWindowBackground
        view.blendingMode = withinWindow ? .withinWindow : .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.isEmphasized = false
        // 原生背景滤镜完整参与合成；明暗密度由其上的中性遮罩调节。
        view.alphaValue = 1
    }
}

/// 背景不截获鼠标，浮动条拖动、内层控件和视频交互维持原有事件路径。
private final class PassiveBackdrop: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 上左亮、右下淡暗的细边，避免均匀双描边把透明表面画成实心卡片。
public struct CaploGlassBorder: View {
    private let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.caploMaterialAccessibilityOverride) private var accessibilityOverride
    private var highContrast: Bool { accessibilityOverride?.highContrast ?? (contrast == .increased) }
    public init(cornerRadius: CGFloat) { radius = cornerRadius }
    public var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(LinearGradient(colors: highContrast
                ? [CaploColor.glassEdge, CaploColor.glassEdge]
                : [CaploColor.glassEdge, CaploColor.glassEdge.opacity(0.18), CaploColor.glassShade],
                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: highContrast ? 1 : 0.75)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

public extension View {
    func caploMaterial(_ kind: CaploMaterialKind = .panel,
                       cornerRadius: CGFloat = CaploMetrics.Radius.panel) -> some View {
        background { CaploMaterialBackground(kind) }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay { CaploGlassBorder(cornerRadius: cornerRadius) }
    }

    /// 仅审核自绘环境与同进程视图的合成，不改生产窗口的 behindWindow 行为，也不抓取桌面。
    func caploMaterialBackdropPreview(withinWindow: Bool) -> some View {
        environment(\.caploMaterialWithinWindowPreview, withinWindow)
    }

    /// 审核工具注入系统偏好的等价策略，不修改 macOS 的辅助功能设置。
    func caploMaterialAccessibilityPreview(reduceTransparency: Bool, highContrast: Bool) -> some View {
        environment(\.caploMaterialAccessibilityOverride,
                    MaterialAccessibilityOverride(reduceTransparency: reduceTransparency, highContrast: highContrast))
    }
}

private struct MaterialAccessibilityOverride: Sendable {
    let reduceTransparency: Bool
    let highContrast: Bool
}

private struct MaterialAccessibilityKey: EnvironmentKey {
    static let defaultValue: MaterialAccessibilityOverride? = nil
}

private struct MaterialPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var caploMaterialAccessibilityOverride: MaterialAccessibilityOverride? {
        get { self[MaterialAccessibilityKey.self] }
        set { self[MaterialAccessibilityKey.self] = newValue }
    }
    var caploMaterialWithinWindowPreview: Bool {
        get { self[MaterialPreviewKey.self] }
        set { self[MaterialPreviewKey.self] = newValue }
    }
}

public extension EnvironmentValues {
    /// 自有预览向 AppKit 子视图转发等价辅助功能策略；生产为 nil，继续读取系统真实设置。
    var caploMaterialHighContrastPreview: Bool? { caploMaterialAccessibilityOverride?.highContrast }
    var caploMaterialOpaquePreview: Bool? {
        guard let override = caploMaterialAccessibilityOverride else { return nil }
        return override.reduceTransparency || override.highContrast
    }
}

import SwiftUI
import CaploDesignSystem

/// 面板参数行：拖动期间只刷新预览，松开时提交一次编辑历史。
/// 卡尺配置按参数类型自动匹配（百分比 / 倍率 / 整数 / 小数），`detents` 给出常用档位让游标吸住。
struct EditorSlider: View {
    let model: VideoEditorModel
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var suffix = ""
    var percentage = false
    var decimals = 2
    var defaultValue: Double? = nil
    var detents: [Double] = []

    var body: some View {
        LabeledCaliper(title, value: $value, configuration: configuration,
                       format: { String(format: percentage ? "%.0f" : "%.\(decimals)f", $0 * (percentage ? 100 : 1)) + suffix },
                       onEditingChanged: { active in if active { model.beginInteraction() } else { model.endInteraction() } })
    }

    private var configuration: CaliperConfiguration {
        var config: CaliperConfiguration
        if percentage { config = .editorPercent(range) }
        else if suffix == "×" { config = .editorMultiplier(range) }
        else if decimals == 0 || range.upperBound - range.lowerBound >= 20 { config = .editorInteger(range) }
        else { config = .editorDecimal(range, decimals: decimals) }
        config.defaultValue = defaultValue
        config.detents = detents
        if !detents.isEmpty { config.magnet = .detents }
        return config
    }
}

/// 编辑器面板里四类参数的卡尺预设。刻度间隔取主刻度的十分之一，中刻度取一半，像素太密时组件自己放粗。
/// 阻尼按手感分档：整数量最沉（0.35），倍率 0.32，滚动小数 0.28，固定轨道的百分比 / 短程小数轻一些（0.2）。
extension CaliperConfiguration {
    /// 0…1 / 0…2 这类按百分比显示的量：固定轨道看得见全程，主刻度 25% 或 50%。
    static func editorPercent(_ range: ClosedRange<Double>) -> CaliperConfiguration {
        let span = range.upperBound - range.lowerBound
        let major = span > 1.2 ? 0.5 : 0.25
        return CaliperConfiguration(track: .fixed, range: range, step: 0.01, tickStep: 0.05, major: major, mid: major / 2, inertia: false, decimals: 2, damping: 0.2)
    }
    /// 倍率（×）：滚动轨道，0.05 步进，主刻度 0.5，默认吸附主刻度。
    static func editorMultiplier(_ range: ClosedRange<Double>) -> CaliperConfiguration {
        CaliperConfiguration(track: .scroll, range: range, step: 0.05, tickStep: 0.05, major: 0.5, mid: 0.25, pxPerUnit: 110, magnet: .major, decimals: 2, suffix: "×", damping: 0.32)
    }
    /// 整数量（留白、圆角、柔和度、距离）：滚动轨道，可见约四成范围。
    static func editorInteger(_ range: ClosedRange<Double>) -> CaliperConfiguration {
        let span = max(1, range.upperBound - range.lowerBound)
        let major = nice(span / 10)
        let mid = (major / 2).truncatingRemainder(dividingBy: 1) == 0 ? major / 2 : nil
        return CaliperConfiguration(track: .scroll, range: range, step: 1, tickStep: max(1, major / 10), major: major, mid: mid,
                                    pxPerUnit: min(10, max(3, 268 / span * 2.2)), decimals: 0, damping: 0.35)
    }
    /// 小数量（秒、比例）：范围窄用固定轨道看全程，范围宽用滚动轨道。
    static func editorDecimal(_ range: ClosedRange<Double>, decimals: Int) -> CaliperConfiguration {
        let span = max(0.000_1, range.upperBound - range.lowerBound)
        let major = nice(span / 5)
        let step = max(nice(span / 100), pow(10, -Double(decimals)))
        let fixed = span <= 1.2
        return CaliperConfiguration(track: fixed ? .fixed : .scroll, range: range, step: step, tickStep: major / 10, major: major, mid: major / 2,
                                    pxPerUnit: min(1500, max(30, 268 / span * 2.2)), inertia: !fixed, decimals: decimals, damping: fixed ? 0.2 : 0.28)
    }
}

/// 面板内的说明文字。
struct PanelNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(CaploFont.footnote).foregroundStyle(CaploColor.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// 新控件的宽度预算：面板内容列 `CaploMetrics.panelContentWidth`（268 点），
/// 装进 `PanelSelection` 之后再减去左右各 10 点留白，只剩 248 点。
/// 列宽是写死的，超出的控件不会再把整列顶宽，而是**静默被裁掉**——没有可见症状提醒你，自己核对。
///
/// 当前选中的那一个的参数卡：表头是图标、名字与起点时间码（只读），下面是参数。
/// 面板里不再摆一整列可折叠的条目——挑哪一个是时间线的事，面板只跟着时间线的选中走，
/// 时间线上换一块，这里的内容跟着换。镜头、遮罩、文字都用它。
struct PanelSelection<Content: View>: View {
    /// 左侧图标。
    let symbol: String
    /// 与时间线块相同的显示名（自定义名优先，多个同类块时带编号）。
    let title: String
    /// 右侧的次要文字，一般是起点时间码。
    let trailing: String
    @ViewBuilder let content: () -> Content
    private var radius: CGFloat { CaploMetrics.Radius.control + 2 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: CaploMetrics.Spacing.s) {
                Image(systemName: symbol).frame(width: CaploMetrics.Icon.control)
                Text(title).font(CaploFont.bodyMedium).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: CaploMetrics.Spacing.s)
                Text(trailing).font(CaploFont.value)
            }
            .padding(.horizontal, 10).frame(height: CaploMetrics.ControlHeight.large)
            .foregroundStyle(CaploColor.textPrimary)
            .background(CaploColor.accentSoft)
            VStack(alignment: .leading, spacing: CaploMetrics.Spacing.s) { content() }
                .padding(.horizontal, 10).padding(.top, CaploMetrics.Spacing.s).padding(.bottom, CaploMetrics.Spacing.m)
                .background(CaploColor.surfaceRaised.opacity(0.5))
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(CaploColor.accent, lineWidth: 1.5))
    }
}

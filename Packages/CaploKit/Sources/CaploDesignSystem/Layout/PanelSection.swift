import SwiftUI

/// 属性面板分区：12 点次级标题，可选信息提示，内容左对齐、8 点间距。
/// 传入 `expanded` 绑定即可折叠：标题右侧出现箭头，整行可点，收起时只剩标题一行；展开收起带动画。
public struct PanelSection<Content: View>: View {
    private let title: String
    private let info: String?
    private let expanded: Binding<Bool>?
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ title: String, info: String? = nil, expanded: Binding<Bool>? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.info = info; self.expanded = expanded; self.content = content()
    }

    private var isExpanded: Bool { expanded?.wrappedValue ?? true }

    public var body: some View {
        VStack(alignment: .leading, spacing: CaploMetrics.Spacing.s) {
            header
            if isExpanded { content.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        // 折叠动画需要裁切，但裁切框要比布局框大 4 点：卡尺的游标三角和焦点环都画在自己边界之外 2 点，
        // 贴着布局框裁会把它们切掉（表现为游标缺角、焦点环断成两段）。
        .padding(4).clipped().padding(-4)
    }

    @ViewBuilder private var header: some View {
        let row = HStack(spacing: CaploMetrics.Spacing.xs) {
            Text(title).font(CaploFont.sectionTitle).foregroundStyle(CaploColor.textSecondary)
            if let info {
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(CaploColor.textTertiary)
                    .help(info).accessibilityLabel(info)
            }
            if expanded != nil {
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(CaploColor.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
        if let expanded {
            Button {
                withAnimation(CaploMotion.animation(0.22, reduceMotion: reduceMotion)) { expanded.wrappedValue.toggle() }
            } label: { row.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "已展开" : "已收起")
        } else { row }
    }
}

/// 面板容器：300 点宽中性玻璃内层，内容可滚动；与时间线共用表面色与工作区卡片亮边。
///
/// 内容列的宽度写死成 `panelWidth` 减去左右留白，不用 `maxWidth: .infinity`：那样一来滚动条的出现与否
/// （系统的"始终显示滚动条"）、或者某个子控件的最小宽度，都会把整列的宽度顶来顶去——展开一段文字就能看见
/// 预设格子跟着变宽变窄。固定宽度之后，过宽的子控件只会自己越界被裁掉，不再牵动同列的其它行。
public struct PanelContainer<Content: View>: View {
    private let title: String
    private let content: Content
    public init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CaploMetrics.Spacing.l) {
                Text(title).font(CaploFont.panelTitle).foregroundStyle(CaploColor.textPrimary)
                content
            }
            .frame(width: CaploMetrics.panelContentWidth, alignment: .leading)
            .padding(CaploMetrics.Spacing.l)
        }
        .frame(width: CaploMetrics.panelWidth)
        .background { CaploMaterialBackground(.panel) }
    }
}

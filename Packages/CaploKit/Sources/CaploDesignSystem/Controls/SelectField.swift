import AppKit
import SwiftUI

/// 面板里占满一行的下拉选择："当前值 + ⌃⌄"，没有值时显示占位文字。
/// 菜单用 `NSMenu` 从控件正下方弹出：SwiftUI `Menu` 在 macOS 上会把自定义标签拆成"图标 + 标题"重画，
/// 底板、整行宽度与右侧箭头都会丢失，所以这里自己画按钮、自己弹菜单；菜单最窄与控件同宽。
public struct SelectField: View {
    public struct Item: Identifiable {
        public let id: String
        public let title: String
        public let checked: Bool
        public let action: @MainActor () -> Void
        public init(id: String, title: String, checked: Bool = false, action: @escaping @MainActor () -> Void) {
            self.id = id; self.title = title; self.checked = checked; self.action = action
        }
    }

    public struct Section {
        public let title: String?
        public let items: [Item]
        public init(_ title: String? = nil, items: [Item]) { self.title = title; self.items = items }
    }

    private let value: String?
    private let placeholder: String
    private let accessibilityName: String
    private let sections: [Section]
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    @State private var anchor = MenuAnchor()

    public init(value: String?, placeholder: String, accessibilityName: String, sections: [Section]) {
        self.value = value; self.placeholder = placeholder; self.accessibilityName = accessibilityName; self.sections = sections
    }

    public var body: some View {
        Button { anchor.popUp(Self.entries(sections)) } label: {
            HStack(spacing: CaploMetrics.Spacing.xs + 2) {
                Text(value ?? placeholder).font(CaploFont.body).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(value == nil ? CaploColor.textSecondary : CaploColor.textPrimary)
                Spacer(minLength: CaploMetrics.Spacing.s)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(CaploColor.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: CaploMetrics.ControlHeight.medium)
            .background {
                CaploMaterialBackground(.raised)
                    .overlay(CaploColor.glassSheen.opacity(hovered ? 1 : 0))
                    .clipShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control))
            }
            .overlay { CaploGlassBorder(cornerRadius: CaploMetrics.Radius.control) }
            .contentShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control))
        }
        .buttonStyle(PopupButtonStyle())
        .background(MenuAnchorView(anchor: anchor))
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(value ?? String(localized: "未选择"))
    }

    /// 分组 → 菜单条目：组间分隔线，有标题的组加节标题。
    static func entries(_ sections: [Section]) -> [PopupMenuEntry] {
        var entries: [PopupMenuEntry] = []
        for (index, section) in sections.enumerated() {
            if index > 0 { entries.append(.separator) }
            if let title = section.title { entries.append(.header(title)) }
            for item in section.items { entries.append(.item(item.title, checked: item.checked, action: item.action)) }
        }
        return entries
    }
}

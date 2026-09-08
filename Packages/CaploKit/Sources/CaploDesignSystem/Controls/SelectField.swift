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
        Button { anchor.popUp(sections) } label: {
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
        .buttonStyle(SelectButtonStyle())
        .background(MenuAnchorView(anchor: anchor))
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(value ?? "未选择")
    }
}

/// 按下变淡；键盘焦点用强调色描边（系统焦点环与圆角底板不贴合）。
private struct SelectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyleBody(configuration: configuration) }

    private struct StyleBody: View {
        let configuration: Configuration
        @FocusState private var focused: Bool
        var body: some View {
            configuration.label
                .overlay {
                    if focused { RoundedRectangle(cornerRadius: CaploMetrics.Radius.control).strokeBorder(CaploColor.accent.opacity(0.9), lineWidth: 2) }
                }
                .opacity(configuration.isPressed ? 0.8 : 1)
                .focused($focused)
                .focusEffectDisabled()
        }
    }
}

/// 记住控件对应的 AppKit 视图，弹菜单时据此定位；菜单项的目标对象在菜单关闭前保持存活。
@MainActor
private final class MenuAnchor {
    weak var view: NSView?
    private var targets: [MenuTarget] = []

    func popUp(_ sections: [SelectField.Section]) {
        guard let view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        targets = []
        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            if let title = section.title { menu.addItem(NSMenuItem.sectionHeader(title: title)) }
            for item in section.items {
                let target = MenuTarget(item.action)
                targets.append(target)
                let entry = NSMenuItem(title: item.title, action: #selector(MenuTarget.fire), keyEquivalent: "")
                entry.target = target
                entry.state = item.checked ? .on : .off
                menu.addItem(entry)
            }
        }
        menu.minimumWidth = view.bounds.width
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4), in: view)
    }
}

@MainActor
private final class MenuTarget: NSObject {
    private let run: @MainActor () -> Void
    init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    @objc func fire() { run() }
}

/// 零尺寸、不响应点击的锚点视图，铺在按钮底下，尺寸即按钮尺寸。
private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor
    func makeNSView(context: Context) -> AnchorView { let view = AnchorView(); anchor.view = view; return view }
    func updateNSView(_ view: AnchorView, context: Context) { anchor.view = view }

    final class AnchorView: NSView {
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

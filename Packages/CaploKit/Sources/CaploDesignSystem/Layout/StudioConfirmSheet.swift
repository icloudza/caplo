import SwiftUI

/// 自绘确认弹层：玻璃底、标题、一句说明、右对齐的"取消 + 主动作"。用 `.sheet` 呈现并清除系统底色，
/// 代替原生 confirmationDialog 的样式。`danger` 为 true 时主动作是实心红按钮。
public struct StudioConfirmSheet: View {
    private let title: String
    private let message: String
    private let confirmTitle: String
    private let danger: Bool
    private let confirm: () -> Void
    private let cancel: () -> Void
    /// 可选的"不再提示"勾选，放在按钮行左侧；由调用方决定勾了之后怎么记住。
    private let suppression: Binding<Bool>?
    private let suppressionTitle: String

    public init(title: String, message: String, confirmTitle: String, danger: Bool = false,
                suppression: Binding<Bool>? = nil, suppressionTitle: String = "不再提示",
                confirm: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.title = title; self.message = message; self.confirmTitle = confirmTitle; self.danger = danger
        self.suppression = suppression; self.suppressionTitle = suppressionTitle
        self.confirm = confirm; self.cancel = cancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CaploMetrics.Spacing.l) {
            Text(title).font(CaploFont.panelTitle).foregroundStyle(CaploColor.textPrimary)
            Text(message).font(CaploFont.body).foregroundStyle(CaploColor.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: CaploMetrics.Spacing.s) {
                if let suppression {
                    Toggle(suppressionTitle, isOn: suppression).toggleStyle(.checkbox)
                        .font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
                }
                Spacer()
                Button("取消", action: cancel).buttonStyle(StudioButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm).buttonStyle(StudioButtonStyle(danger ? .danger : .primary)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(CaploMetrics.Spacing.xl).frame(width: 380)
        .foregroundStyle(CaploColor.textPrimary)
        .background(CaploMaterialBackground(.window))
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
    }
}

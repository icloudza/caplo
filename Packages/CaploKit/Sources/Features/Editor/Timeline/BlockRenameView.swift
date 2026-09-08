import SwiftUI
import CaploDesignSystem

/// 时间线块改名框：从右键菜单"重命名…"弹出，文本框预填自定义名称、占位显示默认名称；回车或"确定"提交，留空恢复默认。
struct BlockRenameView: View {
    let defaultTitle: String
    let commit: (String) -> Void
    let cancel: () -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(title: String, defaultTitle: String, commit: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        _text = State(initialValue: title); self.defaultTitle = defaultTitle; self.commit = commit; self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CaploMetrics.Spacing.m) {
            Text("重命名").font(CaploFont.panelTitle).foregroundStyle(CaploColor.textPrimary)
            TextField(defaultTitle, text: $text)
                .textFieldStyle(.roundedBorder)
                .environment(\.colorScheme, .dark)
                .focused($focused)
                .onSubmit { commit(text) }
            Text("留空则恢复为默认名称。").font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
            HStack {
                Spacer()
                Button("取消") { cancel() }.buttonStyle(StudioButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
                Button("确定") { commit(text) }.buttonStyle(StudioButtonStyle(.primary)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(CaploMetrics.Spacing.l).frame(width: 280)
        .background(CaploMaterialBackground(.floating))
        .foregroundStyle(CaploColor.textPrimary)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }
}

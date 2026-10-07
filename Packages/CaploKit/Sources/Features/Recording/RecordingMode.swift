import CaptureKit

/// 三种录制方式；`kind` 决定来源列表按显示器还是窗口过滤。
enum RecordingMode: String, CaseIterable, Identifiable {
    /// 首次使用引导里的目标 id。
    var onboardingID: String {
        switch self { case .display: "display"; case .region: "region"; case .window: "window" }
    }

    case display = "全屏", region = "自定义区域", window = "窗口"
    var id: Self { self }

    var hint: String {
        switch self { case .display: "录下整个屏幕"; case .region: "框选需要的画面"; case .window: "专注一个应用窗口" }
    }
    var kind: CaptureSource.Kind { self == .window ? .window : .display }
    var symbol: String {
        switch self { case .display: "display"; case .region: "rectangle.dashed"; case .window: "macwindow" }
    }
    /// 方式条上直接选这种方式的快捷键（默认 1 / 2 / 3，可在设置里改）。
    var shortcutAction: ShortcutAction {
        switch self { case .display: .recordDisplay; case .region: .recordRegion; case .window: .recordWindow }
    }
    /// 来源下拉为空时的占位。
    var sourcePlaceholder: String { self == .window ? "选择窗口" : "选择显示器" }
}

import EditingCore
import AppKit
import SwiftUI
import CaploDesignSystem

/// 更新窗口：只开一个，大小随阶段在"带说明的大窗"与"一行状态的小窗"之间切换。
/// 不计入 `AppPresence` 的 Dock 窗口：后台提醒不该把隐藏的 Dock 图标叫回来、也不该抢走焦点。
@MainActor
final class UpdateWindow: NSObject, NSWindowDelegate {
    static let shared = UpdateWindow()
    static let identifier = "caplo-update"
    static let fullSize = CGSize(width: 560, height: 440)
    static let compactSize = CGSize(width: 420, height: 168)

    private var controller: StudioWindowController?
    private var flow: UpdateFlow { AppUpdater.shared.flow }

    var isVisible: Bool { controller?.window?.isVisible == true }

    /// `activate`：用户主动操作时激活应用并成为关键窗口；后台提醒只浮到最前，不打断正在用的应用。
    func present(activate: Bool) {
        let window = makeWindowIfNeeded()
        applySize(animate: window.isVisible)
        if !window.isVisible { window.center() }
        if activate {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderFrontRegardless()
        }
    }

    func hide() { controller?.window?.orderOut(nil) }

    /// 窗口回归：不连 Sparkle，直接给共享状态一个新版本并显示，再切到小窗。
    static func showSmokeSample() {
        let flow = AppUpdater.shared.flow
        flow.offer(UpdateRelease(version: "9.9.9", build: "9009009", notes: "## 新功能\n- 窗口回归样例", size: 1_000_000),
                   downloaded: false, userInitiated: true) { _ in }
        shared.present(activate: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        flow.upToDate("当前版本 9.9.9。") {}
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        flow.reset()
    }

    private func makeWindowIfNeeded() -> NSWindow {
        if let window = controller?.window { return window }
        let size = flow.phase.showsRelease ? Self.fullSize : Self.compactSize
        let controller = StudioWindowController(identifier: Self.identifier, title: String(localized: "软件更新"),
                                                content: UpdateView(flow: flow).ignoresSafeArea(),
                                                sizing: .fixed(size), chrome: .hiddenTitle)
        WindowRegistry.register(controller)
        self.controller = controller
        let window = controller.window!
        window.delegate = self
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.collectionBehavior.insert(.fullScreenNone)
        observePhase()
        return window
    }

    /// 阶段切换（小窗 ↔ 大窗）时调整窗口尺寸，保持顶边不动。
    private func observePhase() {
        withObservationTracking { _ = flow.phase.showsRelease } onChange: {
            Task { @MainActor in
                UpdateWindow.shared.applySize(animate: true)
                UpdateWindow.shared.observePhase()
            }
        }
    }

    private func applySize(animate: Bool) {
        controller?.setFixedContentSize(flow.phase.showsRelease ? Self.fullSize : Self.compactSize,
                                        animate: animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !flow.windowClosing() { sender.orderOut(nil) }
        // 由 flow 的选择决定收起；窗口对象保留复用。
        return false
    }
}

/// 离屏预览与窗口回归用：按名字构造一个阶段，不连 Sparkle。
public struct UpdateWindowPreview: View {
    @State private var flow: UpdateFlow
    public init(state: String) {
        let flow = UpdateFlow(currentVersion: "0.4.2")
        let release = UpdateRelease(version: "0.5.0", build: "5000", date: Date(timeIntervalSince1970: 1_791_331_200),
                                    notes: """
                                    ## 新功能
                                    - 画面比例新增**原始**，默认按录制画面导出
                                      New **Original** aspect ratio, exports at the recorded size
                                    - 录制声音默认跟随画面，可在时间线右键分离
                                      Recorded audio follows the picture; detach it from the timeline menu
                                    ## 修复
                                    - 短片段把手与下一块重叠
                                      Short clip handles overlapping the next clip
                                    """, size: 48_213_504)
        switch state {
        case "checking": flow.beginChecking {}
        case "latest": flow.upToDate("当前版本 0.4.2。") {}
        case "failed": flow.fail("无法连接更新服务器，请检查网络。") {}
        case "downloading":
            flow.offer(release, downloaded: false, userInitiated: true) { _ in }
            flow.beginDownload {}; flow.expectDownload(length: 48_213_504); flow.receive(bytes: 19_660_800)
        case "ready":
            flow.offer(release, downloaded: false, userInitiated: true) { _ in }
            flow.ready { _ in }
        default: flow.offer(release, downloaded: false, userInitiated: true) { _ in }
        }
        _flow = State(initialValue: flow)
    }
    public var body: some View { UpdateView(flow: flow) }
    public static func size(for state: String) -> CGSize {
        ["checking", "latest", "failed"].contains(state) ? UpdateWindow.compactSize : UpdateWindow.fullSize
    }
}

// MARK: - 界面

struct UpdateView: View {
    let flow: UpdateFlow

    var body: some View {
        Group {
            if flow.phase.showsRelease, let release = flow.release { ReleaseLayout(flow: flow, release: release) }
            else { StatusLayout(flow: flow) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CaploMaterialBackground(.window))
        .foregroundStyle(CaploColor.textPrimary)
        .tint(CaploColor.accent)
        .preferredColorScheme(.dark)
    }
}

/// 大窗：图标 + 版本标题，下面是更新说明，底栏随阶段换成按钮、进度或重启选择。
private struct ReleaseLayout: View {
    let flow: UpdateFlow
    let release: UpdateRelease

    var body: some View {
        VStack(alignment: .leading, spacing: CaploMetrics.Spacing.l) {
            HStack(alignment: .center, spacing: CaploMetrics.Spacing.l) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: CaploMetrics.Spacing.s) {
                        Text("Caplo \(release.version)").font(.system(size: 17, weight: .semibold))
                        if release.critical { UpdateBadge(String(localized: "重要更新")) }
                    }
                    Text(subtitle).font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
                }
            }
            ReleaseNotesView(text: release.notes)
            // 底栏固定高度：按钮、进度、安装中几种底栏切换时说明区不跳动。
            footer.frame(height: 40)
        }
        .padding(.horizontal, CaploMetrics.Spacing.xl)
        .padding(.top, CaploMetrics.compactTitleBarHeight + CaploMetrics.Spacing.xs)
        .padding(.bottom, CaploMetrics.Spacing.l)
    }

    /// "当前 0.4.2 · 46 MB · 2026年10月7日"：只列有的项。
    private var subtitle: String {
        var parts = [String(localized: "当前 \(flow.currentVersion)")]
        if let size = release.size { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if let date = release.date { parts.append(date.formatted(.dateTime.year().month().day().locale(AppLocale.current))) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var footer: some View {
        switch flow.phase {
        case .available(let downloaded):
            HStack(spacing: CaploMetrics.Spacing.s) {
                if !release.critical {
                    Button("跳过此版本") { flow.skip() }.buttonStyle(StudioButtonStyle(.quiet, size: .medium))
                }
                Spacer()
                Button("稍后") { flow.later() }.buttonStyle(StudioButtonStyle(.secondary, size: .medium))
                    .keyboardShortcut(.cancelAction)
                Button(release.informationOnly ? "前往下载" : downloaded ? "安装并重新启动" : "立即更新") { flow.install() }
                    .buttonStyle(StudioButtonStyle(.primary, size: .medium))
                    .keyboardShortcut(.defaultAction)
            }
        case .downloading(let received, let expected):
            ProgressFooter(title: String(localized: "正在下载"), detail: expected > 0 ? "\(bytes(received)) / \(bytes(expected))" : bytes(received),
                           fraction: expected > 0 ? Double(received) / Double(expected) : nil) {
                Button("取消") { flow.cancel() }.buttonStyle(StudioButtonStyle(.secondary, size: .medium))
                    .keyboardShortcut(.cancelAction)
            }
        case .extracting(let progress):
            ProgressFooter(title: String(localized: "正在校验"), detail: nil, fraction: progress > 0 ? progress : nil) { EmptyView() }
        case .ready:
            HStack(spacing: CaploMetrics.Spacing.s) {
                Label("已就绪", systemImage: "checkmark.circle.fill")
                    .font(CaploFont.bodyMedium).foregroundStyle(CaploColor.live)
                Spacer()
                Button("退出时安装") { flow.installOnQuit() }.buttonStyle(StudioButtonStyle(.secondary, size: .medium))
                    .keyboardShortcut(.cancelAction)
                Button("重新启动") { flow.restartNow() }.buttonStyle(StudioButtonStyle(.primary, size: .medium))
                    .keyboardShortcut(.defaultAction)
            }
        case .installing(let waitingForQuit):
            HStack(spacing: CaploMetrics.Spacing.s) {
                ProgressView().controlSize(.small)
                Text(waitingForQuit ? "等待 Caplo 退出" : "正在安装").font(CaploFont.bodyMedium)
                Spacer()
                if waitingForQuit {
                    Button("重试") { flow.retryTermination() }.buttonStyle(StudioButtonStyle(.primary, size: .medium))
                }
            }
        default: EmptyView()
        }
    }

    private func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) }
}

/// 下载 / 校验的底栏：标题与字节数一行，下面一条细进度条；右侧放取消。
private struct ProgressFooter<Trailing: View>: View {
    let title: String
    let detail: String?
    /// nil：不知道总量，进度条做不定动画。
    let fraction: Double?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: CaploMetrics.Spacing.l) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(CaploFont.bodyMedium)
                    Spacer()
                    if let detail { Text(detail).font(CaploFont.value).foregroundStyle(CaploColor.textSecondary) }
                }
                UpdateProgressBar(fraction: fraction)
            }
            trailing
        }
    }
}

/// 细进度条：轨道用文字色低透明度，填充用主按钮色；不定进度时一段高光来回移动（减少动态效果时静止）。
struct UpdateProgressBar: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(CaploColor.textPrimary.opacity(0.12))
                if let fraction {
                    Capsule().fill(CaploColor.primaryButtonFill)
                        .frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
                        .animation(.linear(duration: 0.2), value: fraction)
                } else {
                    Capsule().fill(CaploColor.primaryButtonFill.opacity(0.8))
                        .frame(width: proxy.size.width * 0.3)
                        .offset(x: phase ? proxy.size.width * 0.7 : 0)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: phase)
                        .onAppear { phase = true }
                }
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("进度")
        .accessibilityValue(fraction.map { "\(Int($0 * 100))%" } ?? "进行中")
    }
}

/// 小窗：检查中、已是最新、出错。左侧图标，右侧标题与一行说明，按钮在底部右侧。
private struct StatusLayout: View {
    let flow: UpdateFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: CaploMetrics.Spacing.l) {
                symbol.frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if let caption {
                        Text(caption).font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if case .checking = flow.phase { UpdateProgressBar(fraction: nil).padding(.top, 6) }
                }
            }
            Spacer(minLength: CaploMetrics.Spacing.m)
            HStack(spacing: CaploMetrics.Spacing.s) {
                Spacer()
                buttons
            }
        }
        .padding(.horizontal, CaploMetrics.Spacing.xl)
        .padding(.top, CaploMetrics.compactTitleBarHeight + CaploMetrics.Spacing.xs)
        .padding(.bottom, CaploMetrics.Spacing.l)
    }

    @ViewBuilder private var symbol: some View {
        switch flow.phase {
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 28)).foregroundStyle(CaploColor.warning)
        default:
            Image(nsImage: NSApp.applicationIconImage).resizable()
        }
    }

    private var title: String {
        switch flow.phase {
        case .checking: String(localized: "正在检查更新")
        case .upToDate: String(localized: "已是最新版本")
        case .failed: flow.release == nil ? String(localized: "检查更新失败") : String(localized: "更新失败")
        default: ""
        }
    }

    private var caption: String? {
        switch flow.phase {
        case .upToDate(let text), .failed(let text): text
        default: nil
        }
    }

    @ViewBuilder private var buttons: some View {
        switch flow.phase {
        case .checking:
            Button("取消") { flow.cancel() }.buttonStyle(StudioButtonStyle(.secondary, size: .medium)).keyboardShortcut(.cancelAction)
        case .failed:
            if flow.userInitiated {
                Button("重试") { flow.retry() }.buttonStyle(StudioButtonStyle(.secondary, size: .medium))
            }
            Button("好") { flow.acknowledge() }.buttonStyle(StudioButtonStyle(.primary, size: .medium)).keyboardShortcut(.defaultAction)
        default:
            Button("好") { flow.acknowledge() }.buttonStyle(StudioButtonStyle(.primary, size: .medium)).keyboardShortcut(.defaultAction)
        }
    }
}

/// 更新说明：圆角卡片里滚动排版，标题、列表项、段落三种块；行内 Markdown（粗体、代码、链接）照常显示。
private struct ReleaseNotesView: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CaploMetrics.Spacing.s) {
                let blocks = ReleaseNoteBlock.parse(text)
                if blocks.isEmpty {
                    Text("本次更新包含稳定性改进。").font(CaploFont.body).foregroundStyle(CaploColor.textSecondary)
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    switch block {
                    case .heading(let title):
                        Text(inline(title)).font(CaploFont.sectionTitle).foregroundStyle(CaploColor.textSecondary)
                            .padding(.top, index == 0 ? 0 : CaploMetrics.Spacing.s)
                    case .bullet(let item, let detail):
                        HStack(alignment: .firstTextBaseline, spacing: CaploMetrics.Spacing.s) {
                            Circle().fill(CaploColor.textTertiary).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0.height / 2 + 4 }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(inline(item)).font(CaploFont.body)
                                if let detail {
                                    Text(inline(detail)).font(CaploFont.body).foregroundStyle(CaploColor.textSecondary)
                                }
                            }
                        }
                    case .paragraph(let line):
                        Text(inline(line)).font(CaploFont.body).foregroundStyle(CaploColor.textSecondary)
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CaploMetrics.Spacing.l)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity)
        .background(CaploColor.surfaceRaised, in: RoundedRectangle(cornerRadius: CaploMetrics.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CaploMetrics.Radius.card, style: .continuous).strokeBorder(CaploColor.separator))
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

private struct UpdateBadge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(CaploFont.footnote.weight(.semibold)).foregroundStyle(CaploColor.warning)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(CaploColor.warning.opacity(0.16), in: Capsule())
    }
}

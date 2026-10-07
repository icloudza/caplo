import SwiftUI
import AppKit
import CaptureKit
import ProjectKit
import CaploDesignSystem

/// 项目中心、编辑器打开时替换掉的界面；关闭时只回到这里，不再一律弹出录制方式条
/// （从菜单栏打开项目中心再关掉，以前会凭空冒出方式条）。
enum WindowOrigin {
    /// 从菜单栏、快捷键、访达等处打开：关掉就只是关掉。
    case none
    /// 替换了录制方式条或录制条（含录制结束后自动打开编辑器）：关掉回到方式条。
    case recorder
    /// 从项目中心打开编辑器：关掉回到项目中心。
    case library
}

/// 统一管理录制、项目中心和编辑器的路由；原生窗口不依赖 NSHostingView 之外的 Scene 环境。
@MainActor
public enum StudioWindows {
    private static var recorder: NSWindow?
    private static var settings: NSWindow?
    private static var recordBar: StudioWindowController?
    private static var recordBarModel: RecordBarModel?
    /// 用户拖过录制条后不再随区域框自动挪位，直到重新框选或切换来源。
    private static var recordBarDetached = false
    private static var placingRecordBar = false
    private static var recordBarMoveObserver: NSObjectProtocol?
    static var terminating = false

    /// 启动入口：贴在 Dock 上方的录制方式浮动条，与录制条同一构件、同一位置；选定方式后录制条原地替换。
    /// 录制中改为显示控制浮窗。
    public static func showRecorder() {
        guard !terminating else { return }
        if ScreenRecorder.shared.isBusy { RecordingPresentation.shared.revealControls(); return }
        RegionSession.dismiss()
        if recorder == nil {
            let window = make(title: "Caplo", content: ModePickerView(), size: ModePickerView.size, resizable: false,
                              chrome: .borderlessPanel(activating: true), identifier: "caplo-recorder")
            // 入口条只需浮在普通窗口之上，不像录制条那样压过菜单栏。
            window.level = .floating
            recorder = window
        }
        hideRecordBar()
        RecordingFrameSession.dismiss()
        // 入口条与项目中心二选一：从项目中心点"新建录制"回到条时收起项目中心。
        ProjectLibraryWindow.shared.hide()
        if let recorder { dock(recorder, toBottomOf: NSScreen.main) }
        present(recorder)
        OnboardingTour.beginIfNeeded()
    }
    /// 录制方式条窗口（测试用）。
    static var recorderWindow: NSWindow? { recorder }

    /// 录制条显示期间从齿轮菜单打开设置时，设置窗口临时抬到录制条层级，否则会被置顶的覆盖层盖住；
    /// 录制条收起时恢复普通层级。
    public static func showSettings() {
        // 标题保持窗口语义，视觉标题由设置页承担，避免 Aqua 的深色标题压在玻璃背景上。
        if settings == nil { settings = make(title: "设置", content: CaploSettingsView().ignoresSafeArea(), size: CaploSettingsView.size, resizable: false, chrome: .hiddenTitle, identifier: "caplo-settings") }
        settings?.level = recordBar?.window?.isVisible == true ? StudioLevel.bar : .normal
        present(settings)
    }

    static func hideRecorder() { OnboardingTour.dismiss(); recorder?.orderOut(nil) }
    /// 录制方式条或录制条正显示着（新打开的窗口会把它们收起，关掉时要回来）。
    static var preparationVisible: Bool { recorder?.isVisible == true || recordBar?.window?.isVisible == true }

    /// 项目中心或编辑器关闭后按来处收尾。
    static func returnTo(_ origin: WindowOrigin) {
        guard !terminating, !ScreenRecorder.shared.isBusy else { return }
        switch origin {
        case .none: break
        case .recorder: showRecorder()
        case .library: ProjectLibraryWindow.shared.show(restoring: true)
        }
    }

    /// 贴底录制条：替换方式选择窗口；同一模型复用面板，新模型重建内容。
    /// `focusTarget`：窗口模式下不激活本应用，转而把所选窗口的应用带到最前（虚线框随之可见）。
    static func showRecordBar(_ model: RecordBarModel, focusTarget: Bool = false) {
        guard !terminating, !ScreenRecorder.shared.isBusy else { return }
        hideRecorder()
        if recordBar == nil {
            let controller = StudioWindowController(identifier: "caplo-record-bar", title: "录制条", content: RecordBarView(model: model),
                                                    sizing: .fixed(RecordBarView.panelSize), chrome: .borderlessPanel(activating: true))
            WindowRegistry.register(controller)
            recordBar = controller
            if let window = controller.window {
                recordBarMoveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { if !placingRecordBar { recordBarDetached = true } }
                }
            }
        } else if recordBarModel !== model {
            recordBar?.replaceContent(RecordBarView(model: model))
        }
        recordBarModel = model
        // 从倒计时取消或启动失败回到录制条：区域框恢复可编辑外观。
        if model.mode == .region { RegionSession.current?.setRecordingLook(false) }
        guard let window = recordBar?.window else { return }
        // 首次出现或换了模型时回到默认位置；同一模型重复显示（例如区域重新提交）时也重新贴合。
        recordBarDetached = false
        if model.mode == .region, let region = model.region, let screen = model.targetScreen {
            place(window, near: region, on: screen)
        } else if model.mode == .window, let windowID = model.source?.windowID, let bounds = WindowGeometry.onScreenBounds(of: windowID) {
            placeRecordBar(window, nearWindow: bounds)
        } else {
            dock(window, toBottomOf: model.targetScreen)
        }
        if model.mode == .window { WindowHighlightSession.begin(model: model) } else { WindowHighlightSession.dismiss() }
        // 全屏模式从录制条阶段起就在屏幕四角标出取景；其他模式各有自己的提示。
        if model.mode == .display { RecordingFrameSession.begin(on: model.targetScreen ?? NSScreen.main ?? NSScreen.screens[0]) } else { RecordingFrameSession.dismiss() }
        if focusTarget, model.mode == .window {
            window.orderFrontRegardless()
            model.focusSourceApplication()
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        // 窗口显示之后再起试听与预览：同步逻辑只在录制条显示着时才允许起监视。
        model.syncMicrophoneMonitor()
        model.syncCameraMonitor()
    }

    /// 录制条贴在区域框正下方并水平居中；下方放不下时放到框上方；左右钳在可见区域内。
    static func place(_ window: NSWindow, near region: CGRect, on screen: NSScreen) {
        let origin = recordBarOrigin(near: region, screenFrame: screen.frame, visible: screen.visibleFrame, panelSize: window.frame.size)
        placingRecordBar = true
        window.setFrameOrigin(origin)
        placingRecordBar = false
    }

    /// 录制条面板的位置（AppKit 屏幕坐标）。`region` 是显示器本地左上角坐标下的目标框（区域或目标窗口）。
    /// 依次尝试：框正下方 → 框正上方 → 都放不下时贴显示器底部（与全屏模式同一位置，程序坞上方）。
    /// 以前上下都放不下时直接钳进可见区域，几乎占满屏幕的窗口（最大化的浏览器）会让录制条顶到屏幕最上面，
    /// 正好压住目标窗口的标签栏和地址栏，挡住要点的地方。
    static func recordBarOrigin(near region: CGRect, screenFrame: CGRect, visible: CGRect, panelSize: CGSize) -> CGPoint {
        let barHeight = CaploMetrics.floatingBarHeight, padding = CaploMetrics.floatingBarInset
        // 面板比浮动条多一圈留白：上下各 `padding`，浮动条本身在面板中间。
        let regionTop = screenFrame.maxY - region.minY
        let regionBottom = screenFrame.maxY - region.maxY
        let below = regionBottom - CaploMetrics.Spacing.m - barHeight - padding
        let above = regionTop + CaploMetrics.Spacing.m - padding
        let originY: CGFloat
        if below >= visible.minY { originY = below }
        else if above + panelSize.height <= visible.maxY { originY = above }
        else { originY = visible.minY + CaploMetrics.Spacing.xl - padding }
        var originX = screenFrame.minX + region.midX - panelSize.width / 2
        originX = min(max(visible.minX, originX), visible.maxX - panelSize.width)
        return CGPoint(x: originX, y: min(max(visible.minY, originY), visible.maxY - panelSize.height))
    }

    /// 区域框移动 / 调整时让已显示的录制条跟随；用户自己拖过录制条后停止跟随。
    static func followRegion(_ region: CGRect, on screen: NSScreen?) {
        guard let window = recordBar?.window, window.isVisible, let screen, !recordBarDetached else { return }
        place(window, near: region, on: screen)
    }

    /// 窗口模式：录制条贴在目标窗口正下方（放不下则上方），窗口移动时跟随；用户拖过录制条后停止跟随。
    /// `bounds` 为全局左上角原点坐标（`WindowGeometry.onScreenBounds`）。
    static func followWindow(_ bounds: CGRect, primaryHeight: CGFloat? = nil) {
        guard let window = recordBar?.window, window.isVisible, recordBarModel?.mode == .window, !recordBarDetached else { return }
        placeRecordBar(window, nearWindow: bounds, primaryHeight: primaryHeight)
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat { let r = a.intersection(b); return r.isNull ? 0 : r.width * r.height }
    /// 目标窗口所在显示器取窗口中心所在的那块，中心不在任何显示器上时取相交面积最大的一块。
    static func placeRecordBar(_ window: NSWindow, nearWindow bounds: CGRect, primaryHeight: CGFloat? = nil) {
        let height = primaryHeight ?? NSScreen.screens.first?.frame.maxY ?? bounds.maxY
        let appKit = WindowGeometry.appKitRect(fromGlobal: bounds, primaryHeight: height)
        let center = CGPoint(x: appKit.midX, y: appKit.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.max { overlap($0.frame, appKit) < overlap($1.frame, appKit) }
        guard let screen else { return }
        place(window, near: WindowGeometry.localRect(bounds, in: screen.frame, primaryHeight: height), on: screen)
    }

    /// `stopMonitors` 为假表示只是暂时收起（进入录制、临时选窗口）：麦克风试听与摄像头预览继续跑，录制器直接借用它们；
    /// 离开录制流程（关闭录制条、回到入口、打开编辑器）才停。
    static func hideRecordBar(stopMonitors: Bool = true) {
        // 录制中采集归录制器（借用着试听与预览），这里绝不停。
        if stopMonitors, !ScreenRecorder.shared.isBusy { MicrophoneMonitor.shared.stop(); CameraMonitor.shared.stop() }
        WindowHighlightSession.dismiss()
        recordBar?.window?.orderOut(nil)
        settings?.level = .normal
        CameraPreviewCoordinator.refresh()
    }
    static var currentRecordBarModel: RecordBarModel? { recordBarModel }
    static var isRecordBarVisible: Bool { recordBar?.window?.isVisible == true }

    /// 区域模式：开始或重置屏幕框选；首次拖完出现录制条，之后的移动 / 调整实时同步到录制条。
    static func beginRegionSelection(reset: Bool = false) {
        let recorder = ScreenRecorder.shared
        let commit: (RegionSession.Selection) -> Void = { selection in
            let display = recorder.sources.first { $0.kind == .display && $0.displayID == selection.displayID }
                ?? recorder.sources.first { $0.kind == .display }
            guard let display else { return }
            if let model = recordBarModel, model.mode == .region {
                model.updateRegion(selection.rect, display: display)
                showRecordBar(model)
            } else {
                showRecordBar(RecordBarModel(mode: .region, source: display, region: selection.rect))
            }
        }
        let change: (RegionSession.Selection) -> Void = { selection in
            guard let model = recordBarModel, model.mode == .region else { return }
            model.updateRegion(selection.rect, display: recorder.sources.first { $0.kind == .display && $0.displayID == selection.displayID })
            followRegion(selection.rect, on: NSScreen.screens.first { RegionSession.displayID(of: $0) == selection.displayID })
        }
        let cancel: () -> Void = { hideRecordBar(); showRecorder() }
        if reset { RegionSession.reset(onCommit: commit, onChange: change, onCancel: cancel) }
        else { RegionSession.begin(onCommit: commit, onChange: change, onCancel: cancel) }
    }

    /// 把浮动面板放到显示器可见区域底部居中，浮动条底边距可见区域底部 24 点（面板本身含留白）。
    static func dock(_ window: NSWindow, toBottomOf screen: NSScreen?) {
        guard let frame = (screen ?? NSScreen.main)?.visibleFrame else { return }
        placingRecordBar = true
        window.setFrameOrigin(CGPoint(x: frame.midX - window.frame.width / 2,
                                      y: frame.minY + CaploMetrics.Spacing.xl - CaploMetrics.floatingBarInset))
        placingRecordBar = false
    }

    /// 只隐藏窗口，不销毁旧编辑会话；保存失败会保留旧窗口及内存编辑。
    /// 区域模式下框选会话不撤掉，只切换成录制外观，让用户在倒计时与录制期间一直看得到自己框的区域。
    static func prepareForRecording() -> Bool {
        guard VideoEditorSessions.closeCurrent(close: false) else { VideoEditorWindow.shared.reveal(); return false }
        VideoEditorWindow.shared.pauseAndHide()
        hidePreparationWindows(keepRegionOutline: recordBarModel?.mode == .region, stopMonitors: false)
        return true
    }

    /// `keepRegionOutline`：已有的区域框选会话改为只显示虚线的录制外观，而不是撤掉。
    /// `keepRegionOutline` 为 true 表示进入录制流程：区域框与全屏四角都保留；否则（打开编辑器等）一并撤下。
    static func hidePreparationWindows(keepRegionOutline: Bool = false, stopMonitors: Bool = true) {
        if keepRegionOutline, let session = RegionSession.current { session.setRecordingLook(true) } else { RegionSession.dismiss() }
        if !keepRegionOutline { RecordingFrameSession.dismiss() }
        WindowPicker.cancel()
        hideRecorder()
        hideRecordBar(stopMonitors: stopMonitors)
        ProjectLibraryWindow.shared.hide()
        settings?.orderOut(nil)
        AppPresence.update()
    }

    /// 录制取消或启动失败后回到准备阶段：有录制条模型就回到录制条，否则回到方式选择。
    static func returnToPreparation() {
        if let model = recordBarModel { showRecordBar(model) } else { showRecorder() }
    }

    static func reopen() {
        if ScreenRecorder.shared.isBusy { RecordingPresentation.shared.revealControls() }
        else if VideoEditorWindow.shared.isVisible { VideoEditorWindow.shared.reveal() }
        else if recordBar?.window?.isVisible == true, let model = recordBarModel { showRecordBar(model) }
        else { showRecorder() }
    }

    static func present(_ window: NSWindow?) {
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        // 隐藏 Dock 图标时，编辑器 / 项目中心 / 设置一出现就要回到 Dock；不能只等成为关键窗口的通知（应用未激活时可能不发）。
        AppPresence.update()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 所有窗口经 `StudioWindowController` 创建；控制器由 `WindowRegistry` 持有。
    static func make<V: View>(title: String, content: V, size: CGSize, resizable: Bool = true,
                              chrome: StudioWindowController.Chrome = .standard, identifier: String? = nil) -> NSWindow {
        let sizing: StudioWindowController.Sizing = resizable ? .resizable(min: size, initial: size) : .fixed(size)
        let controller = StudioWindowController(identifier: identifier ?? "caplo-\(title)", title: title, content: content,
                                                sizing: sizing, chrome: chrome)
        WindowRegistry.register(controller)
        return controller.window!
    }
}

/// 项目中心始终只开一个窗口，再次点击图标时置前并刷新列表。
@MainActor
public final class ProjectLibraryWindow {
    public static let shared = ProjectLibraryWindow()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var origin = WindowOrigin.none
    /// 打开项目中心时收起录制方式条；关闭时只有当初替换了方式条才把它放回来。
    /// `restoring`：编辑器关闭后回到项目中心，沿用项目中心自己当初的来处，不按此刻（什么都没显示）重算。
    public func show() { show(restoring: false) }
    func show(restoring: Bool) {
        guard !ScreenRecorder.shared.isBusy else { RecordingPresentation.shared.revealControls(); return }
        // 已经开着就沿用原来的来处；从编辑器顶栏打开时编辑器还在，关掉项目中心什么都不用做。
        if !restoring, window?.isVisible != true { origin = StudioWindows.preparationVisible ? .recorder : .none }
        if window == nil {
            // 与编辑器一样把内容延伸到统一标题栏之下：顶栏自行为红黄绿预留空间，不再出现系统标题栏的浅色断层。
            let window = StudioWindows.make(title: "项目中心", content: ProjectLibraryView().ignoresSafeArea(), size: CGSize(width: 900, height: 620), chrome: .unifiedTitle)
            Self.configureManagementWindow(window)
            window.identifier = NSUserInterfaceItemIdentifier("caplo-project-library")
            window.contentMinSize = CGSize(width: 720, height: 460)
            self.window = window
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !VideoEditorWindow.shared.isVisible else { return }
                    let origin = self.origin; self.origin = .none
                    // 下一轮再回到来处，避免在 AppKit 的关闭回调内改变关键窗口。
                    Task { @MainActor in StudioWindows.returnTo(origin) }
                }
            }
        }
        StudioWindows.hideRecorder()
        StudioWindows.present(window)
        Task { await ProjectLibraryModel.shared.refresh() }
    }
    /// 保留边缘调整大小，但项目管理窗口不进入全屏或最小化；两个交通灯完全隐藏。
    static func configureManagementWindow(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.styleMask.remove(.miniaturizable)
        window.collectionBehavior.insert(.fullScreenNone)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }
    func hide() { window?.orderOut(nil); AppPresence.update() }
    var isVisible: Bool { window?.isVisible == true }
}

/// 编辑器持有独立窗口和会话；同一工程重复打开仅置前，切换工程先验证文件，再结束旧会话。
@MainActor
public final class VideoEditorWindow: NSObject, NSWindowDelegate {
    public static let shared = VideoEditorWindow()
    private var window: NSWindow?
    private var model: VideoEditorModel?
    private var openingID = UUID()
    private(set) var opening = false
    /// 当前编辑器保存失败、没能切换过去的工程（多半是刚录完的那一段）：编辑器关掉之后接着打开它，
    /// 不再就此"丢"在项目中心里——录制结束的自动打开只会触发一次。
    private var deferredProject: URL?
    /// 编辑器替换掉的界面，关闭时回到那里。
    private var origin = WindowOrigin.none
    var isVisible: Bool { window?.isVisible == true || window?.isMiniaturized == true }

    /// `origin` 不给就按此刻屏上的界面判断：项目中心开着 → 回项目中心；方式条 / 录制条开着 → 回方式条；
    /// 编辑器已经开着（切换工程）→ 沿用原来的来处；都没有 → 关掉就只是关掉。
    public func show(project: URL) { show(project: project, origin: nil) }
    func show(project: URL, origin explicit: WindowOrigin?) {
        guard !ScreenRecorder.shared.isBusy else {
            let alert = NSAlert()
            alert.messageText = "请先结束当前录制"
            alert.informativeText = "录制保存后即可打开其他工程。"
            alert.runModal()
            return
        }
        let url = project.resolvingSymlinksInPath().standardizedFileURL
        let candidate: WindowOrigin? = explicit ?? (ProjectLibraryWindow.shared.isVisible ? .library
            : StudioWindows.preparationVisible ? .recorder : isVisible ? nil : WindowOrigin.none)
        let id = UUID(); openingID = id
        if model?.entry.url == url {
            opening = false
            StudioWindows.hidePreparationWindows(); reveal(); return
        }
        opening = true
        Task {
            defer { if openingID == id { opening = false } }
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    let loaded = try ProjectStorage.load(url)
                    return loaded.state == .recording ? try ProjectStorage.recover(url) : loaded
                }.value
                guard openingID == id, !ScreenRecorder.shared.isBusy, !StudioWindows.terminating else { return }
                guard VideoEditorSessions.closeCurrent() else { deferredProject = url; reveal(); return }
                deferredProject = nil
                // 打开成功才记来处：打不开时屏上什么都没换，原来的窗口留着。
                if let candidate { origin = candidate }
                let model = VideoEditorModel(entry: LibraryEntry(url: url, document: document))
                self.model = model
                VideoEditorSessions.current = model
                let root = EditorWindowContent(model: model)
                if window == nil {
                    let window = StudioWindows.make(title: document.name, content: root, size: CGSize(width: 1360, height: 860), chrome: .unifiedTitle, identifier: "caplo-video-editor")
                    window.identifier = NSUserInterfaceItemIdentifier("caplo-video-editor")
                    window.contentMinSize = CGSize(width: 1120, height: 720)
                    window.delegate = self
                    self.window = window
                } else { WindowRegistry.controller(for: "caplo-video-editor")?.replaceContent(root) }
                window?.title = document.name
                window?.representedURL = url
                ProjectLibraryModel.remember(url)
                StudioWindows.hidePreparationWindows()
                reveal()
            } catch {
                guard openingID == id else { return }
                let alert = NSAlert()
                alert.messageText = "无法打开工程"
                alert.informativeText = error.localizedDescription
                // 打不开时什么都没收起（收起在打开成功之后），原来的界面原样留着，不再另弹方式条。
                alert.runModal()
            }
        }
    }

    func reveal() { StudioWindows.present(window) }
    func pauseAndHide() {
        model?.pause()
        window?.orderOut(nil)
        AppPresence.update()
    }
    public func windowShouldClose(_ sender: NSWindow) -> Bool { VideoEditorSessions.closeCurrent() }
    public func windowWillClose(_ notification: Notification) {
        openingID = UUID(); opening = false
        model = nil
        window?.contentView = nil
        // 之前因为保存失败没能切过去的工程，现在编辑器关了，接着打开它；否则下一轮恢复准备面板
        // （都放到下一轮，避免在 AppKit 的关闭回调内改变关键窗口）。
        let next = deferredProject; deferredProject = nil
        let origin = self.origin; self.origin = .none
        Task { @MainActor in
            guard !StudioWindows.terminating else { return }
            if let next { self.show(project: next, origin: origin) } else { StudioWindows.returnTo(origin) }
        }
    }
}

private struct EditorWindowContent: View {
    let model: VideoEditorModel
    var body: some View {
        VideoEditorView(model: model) { ProjectLibraryWindow.shared.show() }
            .frame(minWidth: 1120, minHeight: 720)
            .foregroundStyle(CaploColor.textPrimary)
            // 内容延伸到统一标题栏之下：顶栏自行为红黄绿预留空间。
            .ignoresSafeArea()
            .preferredColorScheme(.dark)
    }
}

/// 离屏编辑器使用独立合成工程；不扫描或修改用户的项目列表。
public struct VideoEditorPreview: View {
    @State private var model: VideoEditorModel?
    let projectURL: URL
    let time: Double
    let initialTab: String
    public init(projectURL: URL, time: Double = 0, initialTab: String = "布局") { self.projectURL = projectURL; self.time = time; self.initialTab = initialTab }
    public var body: some View {
        Group {
            if let model { VideoEditorView(model: model, previewTime: time, initialTab: initialTab) {} }
            else { ProgressView("载入预览…") }
        }.task {
            if let document = try? ProjectStorage.load(projectURL) {
                let created = VideoEditorModel(entry: LibraryEntry(url: projectURL, document: document))
                // 离屏缓存显示只认位图内容，预览渲染改用 CGImage 上屏。
                created.canvas.snapshotMode = true
                model = created
            }
        }.onDisappear { model?.close() }
    }
}

/// 导出窗口的离屏预览（PreviewGallery 用）：载入工程后直接画导出窗口本身。
public struct ExportSheetPreview: View {
    @State private var model: VideoEditorModel?
    let projectURL: URL
    public init(projectURL: URL) { self.projectURL = projectURL }
    public var body: some View {
        Group {
            if let model { ExportSheet(model: model) } else { ProgressView("载入预览…") }
        }.task {
            if let document = try? ProjectStorage.load(projectURL) {
                // 编辑器视图会自己调 open()；这里没有编辑器视图，手动打开工程，"导出"按钮与时长才是载入后的样子。
                let created = VideoEditorModel(entry: LibraryEntry(url: projectURL, document: document))
                await created.open()
                model = created
            }
        }.onDisappear { model?.close() }
    }
}

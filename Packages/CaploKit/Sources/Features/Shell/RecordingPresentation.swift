import SwiftUI
import AppKit
import Observation
import CaptureKit
import CaploDesignSystem

/// 浮窗生命周期独立于录制准备窗口；由共享会话驱动，结束后自动转入独立编辑器，取消或启动失败则返回准备面板。
@MainActor
final class RecordingPresentation {
    static let shared = RecordingPresentation()
    private var controller: StudioWindowController?
    private var lastOpened: URL?
    private var wasBusy = false
    private var pulsed = false

    func observe() {
        withObservationTracking {
            let recorder = ScreenRecorder.shared
            if recorder.isBusy {
                wasBusy = true
                StudioWindows.hidePreparationWindows(keepRegionOutline: true)
                showPanel()
                updateFrame(phase: recorder.phase)
            } else {
                controller?.window?.orderOut(nil)
                RecordingFrameSession.dismiss()
                pulsed = false
                let returnedFromRecording = wasBusy
                wasBusy = false
                if !StudioWindows.terminating {
                    if let url = recorder.completedURL, url != lastOpened {
                        lastOpened = url
                        RegionSession.dismiss()
                        VideoEditorWindow.shared.show(project: url)
                    } else if returnedFromRecording { StudioWindows.returnToPreparation() }
                }
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    func revealControls() { if ScreenRecorder.shared.isBusy { showPanel() } }

    /// 全屏模式：四角标记从录制条阶段起一直在；倒计时结束、真正开始录制那一刻整屏脉冲一次；暂停时标记更淡。
    /// 区域模式已有虚线框，窗口模式由被录窗口本身承担提示，都不加框。
    private func updateFrame(phase: ScreenRecorder.Phase) {
        guard let model = StudioWindows.currentRecordBarModel, model.mode == .display else { return }
        RecordingFrameSession.begin(on: model.targetScreen ?? NSScreen.main ?? NSScreen.screens[0])
        switch phase {
        case .idle, .countdown, .starting: return
        case .recording, .pausing, .paused, .resuming, .stopping:
            if !pulsed { pulsed = true; RecordingFrameSession.pulse() }
            RecordingFrameSession.setPaused(phase == .paused || phase == .pausing)
        }
    }

    private func showPanel() {
        if controller == nil {
            let controller = StudioWindowController(identifier: "caplo-recording-controls", title: "录制控制",
                                                    content: LiveRecordingControls(),
                                                    sizing: .fixed(RecordingControls.panelSize),
                                                    chrome: .borderlessPanel(activating: false))
            // 不可共享：系统采集与截屏都不会画它（FocuSee 同款），全屏录制的画面里不会出现控制条。
            controller.window?.sharingType = .none
            WindowRegistry.register(controller)
            self.controller = controller
        }
        guard let window = controller?.window else { return }
        StudioWindows.dock(window, toBottomOf: NSScreen.main)
        window.orderFrontRegardless()
    }
}

/// 倒计时与录制中共用一条浮动条；录制中点击不会激活 Caplo，被录制的应用保持前台。
/// 读数显示到十分之一秒，刷新节拍就是十分之一秒，并且对齐到计时原点：每一跳都正好落在读数变化的时刻，
/// 读数直接由节拍时刻算出，不会因为定时器与计时器相位错开而忽长忽短。暂停时读数冻结，节拍照常但内容不变。
private struct LiveRecordingControls: View {
    private let recorder = ScreenRecorder.shared
    @State private var fallbackOrigin = Date()
    var body: some View {
        TimelineView(.periodic(from: recorder.elapsedOrigin ?? fallbackOrigin, by: 0.1)) { context in
            RecordingControls(state: state(at: context.date),
                              cancel: { recorder.cancelCountdown() },
                              pauseResume: { Task { if recorder.phase == .paused { await recorder.resume() } else { await recorder.pause() } } },
                              stop: { Task { await recorder.stop() } })
        }
    }
    private func state(at date: Date) -> RecordingControls.State {
        if recorder.phase == .countdown { return .countdown(recorder.countdownRemaining) }
        let elapsed = recorder.elapsedOrigin.map { date.timeIntervalSince($0) } ?? recorder.elapsed
        return .recording(elapsed: elapsed, paused: recorder.phase == .paused, stopping: recorder.phase == .stopping, canStop: recorder.canStop)
    }
}

/// 录制控制条的纯展示部分，离屏预览可直接注入状态。
public struct RecordingControls: View {
    public enum State {
        case countdown(Int)
        case recording(elapsed: Double, paused: Bool, stopping: Bool, canStop: Bool)
    }
    /// 高度 = 顶部余量 16 + 浮动条 56 + 面板留白 12。
    public static let panelSize = CGSize(width: 360, height: 84)
    let state: State
    let cancel: () -> Void
    let pauseResume: () -> Void
    let stop: () -> Void

    public init(state: State, cancel: @escaping () -> Void = {}, pauseResume: @escaping () -> Void = {}, stop: @escaping () -> Void = {}) {
        self.state = state; self.cancel = cancel; self.pauseResume = pauseResume; self.stop = stop
    }

    public var body: some View {
        FloatingBar {
            switch state {
            case .countdown(let remaining):
                Circle().fill(CaploColor.record).frame(width: 8, height: 8)
                Text("\(remaining) 秒后开始录制").font(CaploFont.bodyMedium).foregroundStyle(CaploColor.textPrimary)
                FloatingBarDivider()
                Button("取消", action: cancel).buttonStyle(StudioButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
            case .recording(let elapsed, let paused, let stopping, let canStop):
                Circle().fill(paused ? CaploColor.warning : CaploColor.record).frame(width: 8, height: 8)
                Text(Self.timecode(elapsed)).font(CaploFont.timer).foregroundStyle(paused ? CaploColor.textSecondary : CaploColor.textPrimary)
                    .frame(minWidth: 64, alignment: .leading)
                FloatingBarDivider()
                Button(action: pauseResume) { Image(systemName: paused ? "play.fill" : "pause.fill") }
                    .buttonStyle(StudioIconButtonStyle()).disabled(!canStop)
                    .help(paused ? "继续录制" : "暂停录制").accessibilityLabel(paused ? "继续录制" : "暂停录制")
                Button(action: stop) {
                    if stopping { ProgressView().controlSize(.small) } else { Image(systemName: "stop.fill").foregroundStyle(CaploColor.record) }
                }
                .buttonStyle(StudioIconButtonStyle()).disabled(!canStop)
                .help("停止录制并保存").accessibilityLabel(stopping ? "正在保存" : "停止录制并保存")
            }
        }
        .padding(.horizontal, CaploMetrics.floatingBarInset)
        .padding(.bottom, CaploMetrics.floatingBarInset)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .bottom)
        .tint(CaploColor.accent)
        .preferredColorScheme(.dark)
    }

    /// 先四舍五入到十分之一秒再拆分：节拍时刻算出的 0.2999… 要显示成 .3，不能截断成 .2。
    nonisolated public static func timecode(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        return String(format: "%02d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }
}

import AppKit
import Testing
@testable import Features

@MainActor
struct RecordingFrameTests {
    @Test func fullScreenFrameShowsCornersOnTopAndClicksThrough() async throws {
        let screen = try #require(NSScreen.main)
        RecordingFrameSession.begin(on: screen)
        defer { RecordingFrameSession.dismiss() }
        #expect(RecordingFrameSession.isShowing)
        let panel = try #require(NSApp.windows.compactMap { $0 as? NSPanel }.first { $0.contentView is RecordingFrameView })
        #expect(panel.ignoresMouseEvents)
        #expect(panel.level == StudioLevel.overlay)
        #expect(!panel.isOpaque && panel.backgroundColor.alphaComponent < 0.001)
        #expect(panel.frame == screen.frame)
        let view = try #require(panel.contentView as? RecordingFrameView)
        view.layoutSubtreeIfNeeded()
        #expect(view.cornersLayer.path != nil && view.pulseLayer.path != nil)
        // 四角路径贴在屏幕四个角上，不构成一圈。
        let box = try #require(view.cornersLayer.path?.boundingBoxOfPath)
        #expect(abs(box.minX - RecordingFrameView.cornerInset) < 0.5 && abs(box.maxX - (screen.frame.width - RecordingFrameView.cornerInset)) < 0.5)
        #expect(view.cornersLayer.opacity == RecordingFrameView.cornerOpacity)
        // 同一块屏幕重复 begin 不重建面板；脉冲只给描边层加动画，四角不受影响。
        RecordingFrameSession.begin(on: screen)
        #expect(panel.contentView === view)
        RecordingFrameSession.pulse()
        #expect(view.pulseLayer.opacity == 0 && view.cornersLayer.opacity == RecordingFrameView.cornerOpacity)
        RecordingFrameSession.setPaused(true)
        #expect(view.cornersLayer.opacity == RecordingFrameView.pausedOpacity)
        RecordingFrameSession.dismiss()
        #expect(!RecordingFrameSession.isShowing && !panel.isVisible)
    }
}

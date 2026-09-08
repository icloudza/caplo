import AppKit
import Testing
@testable import Features

/// 首次使用引导：只在没看过时随方式条出现，聚光灯落在方式条控件上，看完记住不再出现；方式条收起时撤掉但不算看过。
@Suite(.serialized) @MainActor
struct OnboardingTourTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "caplo.tests.onboarding." + UUID().uuidString)!
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

    @Test func tourShowsOnceAndFollowsTheBar() async throws {
        _ = NSApplication.shared
        OnboardingTour.defaults = freshDefaults()
        defer { OnboardingTour.defaults = .standard; StudioWindows.hideRecorder() }
        StudioWindows.showRecorder()
        let tour = try #require(OnboardingTour.current)
        try await settle()
        let bar = try #require(StudioWindows.recorderWindow?.frame)
        // 首步高亮整条：聚光灯在方式条窗口范围内，且比单个控件宽得多。
        let whole = try #require(tour.spotlight)
        #expect(bar.insetBy(dx: -12, dy: -12).contains(whole) && whole.width > 300)
        tour.next()
        try await settle()
        let display = try #require(tour.spotlight)
        #expect(tour.index == 1 && display.width < whole.width / 3 && whole.contains(display))
        // 键盘：→ 前进、← 后退、⌘ 组合放行。
        #expect(tour.handle(keyCode: 124, command: false) && tour.index == 2)
        #expect(tour.handle(keyCode: 123, command: false) && tour.index == 1)
        #expect(!tour.handle(keyCode: 12, command: true) && tour.index == 1)
        // Esc：记为看过，引导撤掉；再打开方式条不再出现。
        #expect(tour.handle(keyCode: 53, command: false))
        #expect(OnboardingTour.current == nil && OnboardingTour.hasSeen)
        StudioWindows.hideRecorder(); StudioWindows.showRecorder()
        #expect(OnboardingTour.current == nil)
    }

    @Test func hidingTheBarDismissesWithoutMarkingSeen() async throws {
        _ = NSApplication.shared
        OnboardingTour.defaults = freshDefaults()
        defer { OnboardingTour.defaults = .standard; StudioWindows.hideRecorder() }
        StudioWindows.showRecorder()
        #expect(OnboardingTour.current != nil)
        StudioWindows.hideRecorder()
        #expect(OnboardingTour.current == nil && !OnboardingTour.hasSeen)
        // 设置里"重新显示"：清掉标记后再打开方式条又会出现。
        OnboardingTour.hasSeen = true
        OnboardingTour.reset()
        StudioWindows.showRecorder()
        #expect(OnboardingTour.current != nil)
    }

    @Test func tipStaysInsideTheVisibleAreaAndFlipsWhenThereIsNoRoomAbove() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 860)
        let size = CGSize(width: 300, height: 120)
        // 常规：卡片在聚光灯上方、水平居中，箭头指向中心。
        let normal = OnboardingTour.tipFrame(spot: CGRect(x: 600, y: 60, width: 80, height: 40), size: size, visible: visible)
        #expect(!normal.below && normal.frame.minY == 116 && normal.frame.midX == 640 && normal.arrowX == 150)
        // 靠左：卡片钳在边距内，箭头仍指向目标。
        let left = OnboardingTour.tipFrame(spot: CGRect(x: 0, y: 60, width: 40, height: 40), size: size, visible: visible)
        #expect(left.frame.minX == 12 && left.arrowX == 20)
        // 顶部没空间：翻到下方。
        let top = OnboardingTour.tipFrame(spot: CGRect(x: 600, y: 800, width: 80, height: 40), size: size, visible: visible)
        #expect(top.below && top.frame.maxY == 784)
    }
}

extension OnboardingTourTests {
    /// 逃生口：点聚光灯之外的遮罩直接结束；方式条收起后目标找不到，两秒内自行撤掉。
    @Test func clickingOutsideTheSpotlightEndsTheTour() async throws {
        _ = NSApplication.shared
        OnboardingTour.defaults = freshDefaults()
        defer { OnboardingTour.defaults = .standard; StudioWindows.hideRecorder() }
        StudioWindows.showRecorder()
        let tour = try #require(OnboardingTour.current)
        try await settle()
        let shade = try #require(NSApp.windows.compactMap { $0.contentView as? OnboardingShadeView }.first { $0.window?.isVisible == true })
        let spot = try #require(tour.spotlight)
        // 遮罩上远离聚光灯的一点。
        let far = CGPoint(x: spot.minX - 200, y: spot.maxY + 300)
        let local = shade.convert(shade.window!.convertPoint(fromScreen: far), from: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: shade.convert(local, to: nil), modifierFlags: [], timestamp: 0,
                                                   windowNumber: shade.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        shade.mouseDown(with: event)
        #expect(OnboardingTour.current == nil && OnboardingTour.hasSeen)
    }
}

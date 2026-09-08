import AppKit
import Testing
@testable import Features

extension WindowLifecycleTests {
    @Test func navigatorPansResizesBothEndsAndRecentersContinuously() throws {
        let (view, window) = makeNavigatorWindow()
        defer { view.detach(); window.contentView = nil; window.close() }
        var start = 20.0, length = 20.0
        view.onRangeChange = { start = $0; length = $1 }
        view.update(items: [], duration: 100, visibleStart: start, visibleDuration: length, playhead: 30)
        // 可用宽度 1000pt、总长 100 秒，每移动 10pt 对应 1 秒。
        try navigatorMouse(.leftMouseDown, x: 304, view: view, window: window)
        try navigatorMouse(.leftMouseDragged, x: 354, view: view, window: window)
        try navigatorMouse(.leftMouseUp, x: 354, view: view, window: window)
        #expect(abs(start - 25) < 0.001 && abs(length - 20) < 0.001)
        try navigatorMouse(.leftMouseDown, x: view.visibleRangeRect.minX + 2, view: view, window: window)
        try navigatorMouse(.leftMouseDragged, x: 306, view: view, window: window)
        try navigatorMouse(.leftMouseUp, x: 306, view: view, window: window)
        #expect(abs(start - 30) < 0.001 && abs(length - 15) < 0.001)
        try navigatorMouse(.leftMouseDown, x: view.visibleRangeRect.maxX - 2, view: view, window: window)
        try navigatorMouse(.leftMouseDragged, x: 552, view: view, window: window)
        try navigatorMouse(.leftMouseUp, x: 552, view: view, window: window)
        #expect(abs(start - 30) < 0.001 && abs(length - 25) < 0.001)
        try navigatorMouse(.leftMouseDown, x: 104, view: view, window: window)
        #expect(start == 0 && length == 25)
        try navigatorMouse(.leftMouseDragged, x: 154, view: view, window: window)
        try navigatorMouse(.leftMouseUp, x: 154, view: view, window: window)
        #expect(abs(start - 5) < 0.001 && length == 25)
    }

    @Test func navigatorMinimumVisualWidthPreservesActualTimeMapping() throws {
        let (view, window) = makeNavigatorWindow()
        defer { view.detach(); window.contentView = nil; window.close() }
        var start = 40.0, length = 0.1
        view.onRangeChange = { start = $0; length = $1 }
        view.update(items: [], duration: 100, visibleStart: start, visibleDuration: length, playhead: 0)
        #expect(view.visibleRangeRect.width == 24)
        let center = view.visibleRangeRect.midX
        try navigatorMouse(.leftMouseDown, x: center, view: view, window: window)
        try navigatorMouse(.leftMouseDragged, x: center + 50, view: view, window: window)
        try navigatorMouse(.leftMouseUp, x: center + 50, view: view, window: window)
        #expect(abs(start - 45) < 0.001 && abs(length - 0.1) < 0.001)
        let edge = view.visibleRangeRect.maxX - 2
        try navigatorMouse(.leftMouseDown, x: edge, view: view, window: window)
        try navigatorMouse(.leftMouseDragged, x: edge + 10, view: view, window: window)
        try navigatorMouse(.leftMouseUp, x: edge + 10, view: view, window: window)
        #expect(abs(start - 45) < 0.001 && abs(length - 1.1) < 0.001)
    }

    @Test func navigatorDragFreezesTimeScaleAndCancellationRestoresRange() throws {
        let (view, window) = makeNavigatorWindow()
        defer { view.detach(); window.contentView = nil; window.close() }
        var received: [(Double, Double)] = []
        view.update(items: [], duration: 100, visibleStart: 20, visibleDuration: 20, playhead: 0)
        view.onRangeChange = { start, length in
            received.append((start, length))
            // 模拟父时间线在拖动中扩展总范围；本次交互仍使用按下时比例。
            view.updateVisibleRange(start: start, duration: length, totalDuration: 200)
        }
        try navigatorMouse(.leftMouseDown, x: 304, view: view, window: window)
        try navigatorMouse(.leftMouseDragged, x: 354, view: view, window: window)
        #expect(view.isInteracting && received.last?.0 == 25)
        try navigatorMouse(.leftMouseDragged, x: 404, view: view, window: window)
        #expect(received.last?.0 == 30 && received.last?.1 == 20)
        view.cancelInteraction()
        #expect(!view.isInteracting && received.last?.0 == 20 && received.last?.1 == 20)
    }

    @Test func navigatorPlaybackAndPanningReuseOverviewAndResizeSynchronously() {
        _ = NSApplication.shared
        let view = TimelineNavigatorView(frame: CGRect(x: 0, y: 0, width: 1008, height: TimelineNavigatorView.preferredHeight))
        defer { view.detach() }
        let items = (0..<100_000).map { number in
            TimelineNavigatorItem(id: UUID(), start: Double(number), duration: 0.4, kind: .screen)
        }
        view.update(items: items, duration: 100_000, visibleStart: 20_000, visibleDuration: 20_000, playhead: 25_000)
        let buildCount = view.overviewBuildCount
        for number in 0..<120 {
            view.updateVisibleRange(start: 20_000 + Double(number), duration: 20_000, totalDuration: 100_000)
            view.updatePlayhead(25_000 + Double(number))
        }
        #expect(view.overviewBuildCount == buildCount, "总览平移与播放不能反复遍历十万片段")
        view.setFrameSize(CGSize(width: 508, height: TimelineNavigatorView.preferredHeight))
        #expect(view.overviewBuildCount == buildCount + 1)
        #expect(abs(view.visibleRangeRect.width - 100) < 0.001, "视图改变尺寸的同一次调用内更新总览几何")
        let paths = view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.compactMap(\.path) ?? []
        #expect(paths.allSatisfy { $0.boundingBoxOfPath.isEmpty || $0.boundingBoxOfPath.maxX <= 505 })
    }

    @Test func navigatorAcceptsParentZoomLimitDuringHandleDrag() throws {
        let (view, window) = makeNavigatorWindow()
        defer { view.detach(); window.contentView = nil; window.close() }
        view.update(items: [], duration: 100, visibleStart: 20, visibleDuration: 20, playhead: 0)
        view.onRangeChange = { start, length in
            view.updateVisibleRange(start: start, duration: max(10, length), totalDuration: 100)
        }
        try navigatorMouse(.leftMouseDown, x: 402, view: view, window: window)
        try navigatorMouse(.leftMouseDragged, x: 252, view: view, window: window)
        #expect(view.isInteracting && abs(view.visibleRangeRect.width - 100) < 0.001)
        try navigatorMouse(.leftMouseUp, x: 252, view: view, window: window)
        #expect(!view.isInteracting && abs(view.visibleRangeRect.width - 100) < 0.001)
    }

    private func makeNavigatorWindow() -> (TimelineNavigatorView, NSWindow) {
        _ = NSApplication.shared
        let view = TimelineNavigatorView(frame: CGRect(x: 0, y: 0, width: 1008, height: TimelineNavigatorView.preferredHeight))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        return (view, window)
    }
    private func navigatorMouse(_ type: NSEvent.EventType, x: Double, view: TimelineNavigatorView, window: NSWindow) throws {
        let event = try #require(NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: x, y: view.bounds.midY), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseUp(with: event)
        }
    }
}

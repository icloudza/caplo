import AppKit
import Testing
import CaploDesignSystem
@testable import Features

/// 卡尺滑块：几何映射、量化、鼠标 / 滚轮 / 键盘、吸附与区间，全部在真实窗口里跑 AppKit 事件。
@MainActor
struct CaliperSliderTests {
    private func make(_ configuration: CaliperConfiguration, value: Double = 0, handles: Int = 1, lower: Double = 0, upper: Double = 0, width: CGFloat = 268) -> (CaliperView, NSWindow) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width + 40, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = CaliperView(configuration: configuration, value: value, lower: lower, upper: upper, handles: handles)
        view.reduceMotion = true   // 测试里不要惯性和滑动动画
        view.frame = CGRect(x: 20, y: 20, width: width, height: configuration.height)
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }
    private func mouse(_ type: NSEvent.EventType, x: CGFloat, in view: CaliperView, window: NSWindow, clicks: Int = 1) throws {
        let point = view.convert(CGPoint(x: x, y: view.bounds.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: Issue.record("不支持的事件")
        }
    }

    @Test func scrollTrackDragMovesTicksAndCommitsOnce() throws {
        let (view, window) = make(CaliperConfiguration(track: .scroll, range: 0...120, step: 1, major: 10, mid: 5, pxPerUnit: 5, inertia: false, defaultValue: 40), value: 40)
        defer { window.close() }
        var values: [Double] = [], editing: [Bool] = []
        view.onChange = { values.append($0) }; view.onEditingChanged = { editing.append($0) }
        #expect(abs(view.x(for: 40) - view.bounds.midX) < 0.5)   // 滚动轨道：当前值永远在正中
        try mouse(.leftMouseDown, x: 134, in: view, window: window)
        try mouse(.leftMouseDragged, x: 84, in: view, window: window)   // 向左拖 50 点 = +10
        try mouse(.leftMouseUp, x: 84, in: view, window: window)
        #expect(view.value == 50)
        #expect(abs(view.x(for: 50) - view.bounds.midX) < 0.5)
        #expect(editing == [true, false])
        #expect(values.last == 50 && !values.isEmpty)
    }

    @Test func fixedTrackClickJumpsAndClampsToRange() throws {
        let (view, window) = make(CaliperConfiguration(track: .fixed, range: 0...100, step: 1, major: 25, mid: 5, inertia: false), value: 0)
        defer { window.close() }
        let x75 = view.x(for: 75)
        try mouse(.leftMouseDown, x: x75, in: view, window: window)
        #expect(view.value == 75)
        try mouse(.leftMouseDragged, x: view.bounds.width + 200, in: view, window: window)
        try mouse(.leftMouseUp, x: view.bounds.width + 200, in: view, window: window)
        #expect(view.value == 100)
        #expect(abs(view.value(atX: view.x(for: 33)) - 33) < 0.01)
    }

    @Test func keyboardStepsAndShiftTensAndDoubleClickResets() throws {
        let (view, window) = make(CaliperConfiguration(track: .scroll, range: 0...40, step: 1, major: 10, mid: 5, pxPerUnit: 9, inertia: false, defaultValue: 12), value: 12)
        defer { window.close() }
        window.makeFirstResponder(view)
        func key(_ code: UInt16, shift: Bool = false) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: window.windowNumber,
                                                     context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            view.keyDown(with: event)
        }
        try key(124); #expect(view.value == 13)
        try key(124, shift: true); #expect(view.value == 23)
        try key(123); #expect(view.value == 22)
        try key(115); #expect(view.value == 0)
        try key(119); #expect(view.value == 40)
        var resets = 0; view.onReset = { resets += 1 }
        try mouse(.leftMouseDown, x: 100, in: view, window: window, clicks: 2)
        #expect(view.value == 12 && resets == 1)
    }

    @Test func detentMagnetPullsToNearestStopOnRelease() throws {
        let (view, window) = make(CaliperConfiguration(track: .scroll, range: 1...3, step: 0.05, tickStep: 0.05, major: 0.5, mid: 0.25, pxPerUnit: 110,
                                                       detents: [1.5, 2, 2.5], magnet: .detents, inertia: false, decimals: 2), value: 1.8)
        defer { window.close() }
        // 拖到 1.96（距档位 0.04 < 0.5 × 18%），松手吸到 2.0；拖到 1.7 则留在原地。
        try mouse(.leftMouseDown, x: 134, in: view, window: window)
        try mouse(.leftMouseDragged, x: 134 - 0.16 * 110, in: view, window: window)
        try mouse(.leftMouseUp, x: 134 - 0.16 * 110, in: view, window: window)
        #expect(abs(view.value - 2.0) < 1e-9)
        try mouse(.leftMouseDown, x: 134, in: view, window: window)
        try mouse(.leftMouseDragged, x: 134 + 0.3 * 110, in: view, window: window)
        try mouse(.leftMouseUp, x: 134 + 0.3 * 110, in: view, window: window)
        #expect(abs(view.value - 1.7) < 1e-9)
    }

    @Test func detentsOnlySnapsToStopsAndStepsBetweenThem() throws {
        let (view, window) = make(CaliperConfiguration(track: .fixed, range: 0...10, step: 1, major: 5, mid: 1, detents: [0, 3, 5, 10], magnet: .detents, snapTo: .detents, inertia: false), value: 3)
        defer { window.close() }
        try mouse(.leftMouseDown, x: view.x(for: 6), in: view, window: window)
        try mouse(.leftMouseUp, x: view.x(for: 6), in: view, window: window)
        #expect(view.value == 5)
        view.setValue(4); #expect(view.value == 3 || view.value == 5)   // 外部设值也只落在档位上
        window.makeFirstResponder(view)
        let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        view.setValue(3); view.keyDown(with: right); #expect(view.value == 5)
    }

    @Test func rangeHandlesGrabNearestAndBodyMovesBoth() throws {
        let (view, window) = make(CaliperConfiguration(track: .fixed, range: 0...60, step: 1, major: 10, mid: 5, inertia: false), handles: 2, lower: 12, upper: 38)
        defer { window.close() }
        var ranges: [(Double, Double)] = []
        view.onRangeChange = { ranges.append(($0, $1)) }
        let unit = view.x(for: 1) - view.x(for: 0)
        // 拖上游标
        try mouse(.leftMouseDown, x: view.x(for: 38), in: view, window: window)
        try mouse(.leftMouseDragged, x: view.x(for: 38) + 10 * unit, in: view, window: window)
        try mouse(.leftMouseUp, x: view.x(for: 38) + 10 * unit, in: view, window: window)
        #expect(view.lowerValue == 12 && view.upperValue == 48)
        // 拖中段整体平移
        try mouse(.leftMouseDown, x: view.x(for: 30), in: view, window: window)
        try mouse(.leftMouseDragged, x: view.x(for: 30) - 12 * unit, in: view, window: window)
        try mouse(.leftMouseUp, x: view.x(for: 30) - 12 * unit, in: view, window: window)
        #expect(view.lowerValue == 0 && view.upperValue == 36)
        // 下游标不能越过上游标
        try mouse(.leftMouseDown, x: view.x(for: 0), in: view, window: window)
        try mouse(.leftMouseDragged, x: view.x(for: 59), in: view, window: window)
        try mouse(.leftMouseUp, x: view.x(for: 59), in: view, window: window)
        #expect(view.lowerValue == 35 && view.upperValue == 36)
        #expect(!ranges.isEmpty)
    }

    @Test func disabledIgnoresInputAndAccessibilityExposesSlider() throws {
        let (view, window) = make(CaliperConfiguration(track: .scroll, range: 0...100, step: 1, major: 10, inertia: false), value: 20)
        defer { window.close() }
        view.isEnabled = false
        try mouse(.leftMouseDown, x: 134, in: view, window: window)
        try mouse(.leftMouseDragged, x: 34, in: view, window: window)
        try mouse(.leftMouseUp, x: 34, in: view, window: window)
        #expect(view.value == 20 && view.alphaValue < 0.5)
        view.isEnabled = true
        #expect(view.accessibilityRole() == .slider)
        #expect(view.accessibilityPerformIncrement() && view.value == 21)
        #expect(view.accessibilityPerformDecrement() && view.value == 20)
        #expect(view.accessibilityValue() as? String == "20")
    }

    @Test func editorPresetsPickSensibleTicks() {
        let percent = CaliperConfiguration.editorPercent(0...1)
        #expect(percent.track == .fixed && percent.major == 0.25 && percent.step == 0.01)
        let integer = CaliperConfiguration.editorInteger(0...120)
        #expect(integer.track == .scroll && integer.major == 10 && integer.mid == 5 && integer.pxPerUnit >= 3 && integer.pxPerUnit <= 10)
        let seconds = CaliperConfiguration.editorDecimal(0.5...5, decimals: 2)
        #expect(seconds.track == .scroll && seconds.major == 1 && seconds.step == 0.05)
        let narrow = CaliperConfiguration.editorDecimal(0.2...0.9, decimals: 2)
        #expect(narrow.track == .fixed && narrow.major == 0.1)
        #expect(CaliperConfiguration.nice(17) == 20 && CaliperConfiguration.nice(4) == 5 && CaliperConfiguration.nice(0.14) == 0.1 && CaliperConfiguration.nice(2.3) == 2.5)
    }
}

extension CaliperSliderTests {
    /// 上下界相等（镜头已铺满整段录制时的"起点"）或非法的范围不能算出 NaN 几何：CALayer 对 NaN 会抛异常直接崩溃。
    @Test func degenerateRangesKeepFiniteGeometry() {
        for range in [1.43...1.43, 0...0, 5...5] {
            let (view, window) = make(.editorDecimal(range, decimals: 2), value: range.lowerBound)
            defer { window.close() }
            #expect(view.x(for: view.value).isFinite)
            #expect(view.x(for: range.upperBound).isFinite)
            #expect(view.value(atX: 100).isFinite)
            #expect(view.value == range.lowerBound)
        }
        let (fixed, window) = make(CaliperConfiguration(track: .fixed, range: 2...2, step: 0.01), value: 2)
        defer { window.close() }
        #expect(fixed.x(for: 2).isFinite)
    }
}

@MainActor private final class TickRecorder: CaliperTickPlaying {
    var ticks = 0
    func tick() { ticks += 1 }
}

extension CaliperSliderTests {
    private func press(_ code: UInt16, in view: CaliperView, window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                 context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        view.keyDown(with: event)
    }

    /// 阻尼：拖动后显示值先落后于指针，随帧逼近；松手后落定到量化值并结束编辑。
    @Test func dampedDragLagsBehindThePointerThenCatchesUpAndSettles() throws {
        let (view, window) = make(CaliperConfiguration(track: .scroll, range: 0...120, step: 1, major: 10, mid: 5, pxPerUnit: 5, inertia: false, damping: 0.5), value: 40)
        defer { window.close() }
        view.reduceMotion = false
        var editing: [Bool] = []
        view.onEditingChanged = { editing.append($0) }
        try mouse(.leftMouseDown, x: 134, in: view, window: window)
        try mouse(.leftMouseDragged, x: 84, in: view, window: window)   // 指针目标 +10
        view.advanceAnimationForTesting(by: 1.0 / 60)
        #expect(view.displayedValue > 40 && view.displayedValue < 50)
        // 对外值按步量化：显示值 42.4 时对外是 42，不会每帧吐一个小数。
        #expect(abs(view.value - view.displayedValue) <= 0.5 && view.value == view.value.rounded())
        view.advanceAnimationForTesting(by: 0.6)
        #expect(abs(view.displayedValue - 50) < 0.05)
        try mouse(.leftMouseUp, x: 84, in: view, window: window)
        view.advanceAnimationForTesting(by: 1)
        #expect(view.value == 50 && view.displayedValue == 50)
        #expect(editing == [true, false])
    }

    /// 越过端点：显示值带阻力拉出范围（最多 48 点），对外值仍夹在端点；松手弹回端点并结束编辑。
    @Test func draggingPastTheEndRubberBandsThenSpringsBack() throws {
        let (view, window) = make(CaliperConfiguration(track: .scroll, range: 0...120, step: 1, major: 10, mid: 5, pxPerUnit: 5, inertia: false, damping: 0.4), value: 100)
        defer { window.close() }
        view.reduceMotion = false
        try mouse(.leftMouseDown, x: 134, in: view, window: window)
        try mouse(.leftMouseDragged, x: 134 - 5 * 300, in: view, window: window)   // 指针目标 400，远超 120
        view.advanceAnimationForTesting(by: 0.8)
        #expect(view.displayedValue > 120 && view.displayedValue < 120 + 48.0 / 5)
        #expect(view.value == 120)
        try mouse(.leftMouseUp, x: 134 - 5 * 300, in: view, window: window)
        #expect(view.isInteracting)
        view.advanceAnimationForTesting(by: 2)
        #expect(view.displayedValue == 120 && view.value == 120 && !view.isInteracting)
    }

    /// 音效：滚动轨道每跨一步响一声（同一种声音）；固定轨道与全局关闭时不响。
    @Test func scrollTrackClicksOncePerStepAndFixedTrackIsSilent() throws {
        let recorder = TickRecorder()
        let previous = CaliperView.tickPlayer, interval = CaliperView.tickInterval
        CaliperView.tickPlayer = recorder; CaliperView.tickInterval = 0
        defer { CaliperView.tickPlayer = previous; CaliperView.tickInterval = interval; CaliperView.soundsEnabled = true }
        let (view, window) = make(CaliperConfiguration(track: .scroll, range: 0...40, step: 1, major: 10, mid: 5, pxPerUnit: 9, inertia: false), value: 12)
        defer { window.close() }
        window.makeFirstResponder(view)
        for _ in 0..<3 { try press(124, in: view, window: window) }
        #expect(view.value == 15 && recorder.ticks == 3)
        // 拖动经过多个刻度：每帧最多一声，但确实会响。
        recorder.ticks = 0
        try mouse(.leftMouseDown, x: 134, in: view, window: window)
        try mouse(.leftMouseDragged, x: 134 + 9 * 4, in: view, window: window)
        try mouse(.leftMouseUp, x: 134 + 9 * 4, in: view, window: window)
        #expect(view.value == 11 && recorder.ticks == 1)

        let (fixed, second) = make(CaliperConfiguration(track: .fixed, range: 0...40, step: 1, major: 10, mid: 5), value: 12)
        defer { second.close() }
        recorder.ticks = 0
        second.makeFirstResponder(fixed)
        for _ in 0..<3 { try press(124, in: fixed, window: second) }
        #expect(fixed.value == 15 && recorder.ticks == 0)

        CaliperView.soundsEnabled = false
        window.makeFirstResponder(view)
        try press(124, in: view, window: window)
        #expect(recorder.ticks == 0)
    }

    /// 防抖：间隔内的多步只响一声，刚反向要再等一倍时间；间隔过了才响下一声。
    @Test func rapidBackAndForthIsDebounced() throws {
        let recorder = TickRecorder()
        let previous = CaliperView.tickPlayer, interval = CaliperView.tickInterval
        CaliperView.tickPlayer = recorder; CaliperView.tickInterval = 0.03
        defer { CaliperView.tickPlayer = previous; CaliperView.tickInterval = interval }
        let (view, window) = make(CaliperConfiguration(track: .scroll, range: 0...40, step: 1, major: 10, mid: 5, pxPerUnit: 9, inertia: false), value: 20)
        defer { window.close() }
        window.makeFirstResponder(view)
        for code in [UInt16(124), 123, 124, 123, 124] { try press(code, in: view, window: window) }
        #expect(recorder.ticks == 1)
        usleep(40_000)
        try press(124, in: view, window: window)   // 同向、超过 30 毫秒：响
        #expect(recorder.ticks == 2)
        usleep(40_000)
        try press(123, in: view, window: window)   // 反向、不足 60 毫秒：不响
        #expect(recorder.ticks == 2)
        usleep(70_000)
        try press(123, in: view, window: window)
        #expect(recorder.ticks == 3)
    }

    /// 惯性最小化：再快的甩动，松手后也只多溜十几个单位就落定。
    @Test func inertiaIsShortEvenAfterAViolentFling() throws {
        let (view, window) = make(CaliperConfiguration(track: .scroll, range: 0...400, step: 1, major: 10, mid: 5, pxPerUnit: 5, damping: 0.3), value: 40)
        defer { window.close() }
        view.reduceMotion = false
        try mouse(.leftMouseDown, x: 134, in: view, window: window)
        try mouse(.leftMouseDragged, x: 84, in: view, window: window)   // 事件时间戳相同：速度按最快算
        try mouse(.leftMouseUp, x: 84, in: view, window: window)
        view.advanceAnimationForTesting(by: 2)
        #expect(!view.isInteracting)
        #expect(view.value > 40 && view.value <= 40 + 10 + 15)
    }

    /// 滚轮只在持有焦点时改值：没焦点时事件交给上层（面板滚动），值不动；点过或 Tab 到滑块后才生效。
    @Test func wheelOnlyAdjustsAFocusedCaliper() throws {
        let (view, window) = make(CaliperConfiguration(track: .scroll, range: 0...40, step: 1, major: 10, mid: 5, pxPerUnit: 9, inertia: false), value: 12)
        defer { window.close() }
        func wheel(_ delta: Double) throws {
            let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(delta), wheel2: 0, wheel3: 0))
            view.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
        }
        window.makeFirstResponder(nil)
        try wheel(24)
        #expect(view.value == 12 && !view.isInteracting)
        window.makeFirstResponder(view)
        try wheel(24)
        #expect(view.value != 12 && view.isInteracting)
        let (loose, second) = make(CaliperConfiguration(track: .scroll, range: 0...40, step: 1, major: 10, mid: 5, pxPerUnit: 9, inertia: false), value: 12)
        defer { second.close() }
        loose.wheelRequiresFocus = false
        second.makeFirstResponder(nil)
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 24, wheel2: 0, wheel3: 0))
        loose.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
        #expect(loose.value != 12)
    }

    /// 点到滑块之外就交出焦点，之后滚轮不再改值；Esc 同样交出焦点。
    @Test func clickingOutsideOrPressingEscapeReleasesFocus() throws {
        let (view, window) = make(CaliperConfiguration(track: .scroll, range: 0...40, step: 1, major: 10, mid: 5, pxPerUnit: 9, inertia: false), value: 12)
        defer { window.close() }
        try mouse(.leftMouseDown, x: 134, in: view, window: window)
        try mouse(.leftMouseUp, x: 134, in: view, window: window)
        #expect(window.firstResponder === view && view.isShowingFocusRing)   // 点进来就画焦点环
        // 窗口左下角 (4, 4) 在滑块之外：经应用事件分发（触发本地监听）后焦点应交出。
        let outside = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 4, y: 4), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        NSApplication.shared.sendEvent(outside)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))   // 交出焦点安排在下一轮运行循环
        #expect(window.firstResponder !== view && !view.isShowingFocusRing)
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 24, wheel2: 0, wheel3: 0))
        view.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
        #expect(view.value == 12)

        window.makeFirstResponder(view)
        #expect(window.firstResponder === view)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        #expect(window.firstResponder !== view && !view.isShowingFocusRing)
    }

    /// 性能：拖动期间对外值只在跨过刻度步时变化；指针停住后显示链路停掉，不再每帧工作。
    @Test func draggingEmitsOnlyOnStepCrossingsAndIdlesWhenThePointerRests() throws {
        let (view, window) = make(CaliperConfiguration(track: .scroll, range: 0...120, step: 1, major: 10, mid: 5, pxPerUnit: 5, inertia: false, damping: 0.4), value: 40)
        defer { window.close() }
        view.reduceMotion = false
        var emitted: [Double] = []
        view.onChange = { emitted.append($0) }
        try mouse(.leftMouseDown, x: 134, in: view, window: window)
        try mouse(.leftMouseDragged, x: 84, in: view, window: window)   // +10
        view.advanceAnimationForTesting(by: 1)
        #expect(emitted.allSatisfy { $0 == $0.rounded() })
        #expect(Set(emitted).count == emitted.count && emitted.count <= 10)
        #expect(!view.isAnimatingForTesting)
        try mouse(.leftMouseDragged, x: 34, in: view, window: window)   // 再 +10：指针动了才重启
        #expect(view.isAnimatingForTesting)
        view.advanceAnimationForTesting(by: 1)
        #expect(view.value == 60 && !view.isAnimatingForTesting)
        try mouse(.leftMouseUp, x: 34, in: view, window: window)
        view.advanceAnimationForTesting(by: 1)
        #expect(view.value == 60 && !view.isInteracting)
    }

    /// 两个滑块之间来回点多次：焦点始终跟着被点的那个，滚轮只改有焦点的，监听不残留。
    @Test func focusSwitchesCleanlyBetweenTwoCalipers() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let config = CaliperConfiguration(track: .scroll, range: 0...40, step: 1, major: 10, mid: 5, pxPerUnit: 9, inertia: false)
        let a = CaliperView(configuration: config, value: 10), b = CaliperView(configuration: config, value: 20)
        for (view, y) in [(a, 130.0), (b, 30.0)] {
            view.reduceMotion = true
            view.frame = CGRect(x: 20, y: y, width: 268, height: config.height)
            window.contentView?.addSubview(view); view.layoutSubtreeIfNeeded()
        }
        // 离屏窗口不会把点击路由到子视图：先经应用分发让焦点监听看到这一击，再直接派给视图，最后跑一轮运行循环执行延后的交出。
        func click(_ view: CaliperView) throws {
            let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                NSApplication.shared.sendEvent(event)
                if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        for round in 0..<12 {
            let target = round % 2 == 0 ? a : b, other = round % 2 == 0 ? b : a
            try click(target)
            #expect(window.firstResponder === target && CaliperView.focusedForTesting === target)
            #expect(target.isShowingFocusRing && !other.isShowingFocusRing)
            let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 24, wheel2: 0, wheel3: 0))
            let before = (a.value, b.value)
            other.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
            #expect((a.value, b.value) == before)
            target.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
            #expect(target.value != (target === a ? before.0 : before.1))
        }
        // 点到两个滑块之外：焦点交出，监听不再记着任何滑块。
        let blank = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 4, y: 100), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        NSApplication.shared.sendEvent(blank)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        #expect(window.firstResponder !== a && window.firstResponder !== b && CaliperView.focusedForTesting == nil)
    }
}

import AppKit
import AVFoundation
import SwiftUI
import CaploDesignSystem
import EditingCore
import ProjectKit
import Testing
@testable import Features

extension WindowLifecycleTests {
    @Test func focusTrailingHandleAcceptsItsOutsideHitAreaAndShrinksToTheLeft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        model.seek(1); model.addFocus()
        let id = try #require(model.selectedFocus)
        let original = try #require(model.edit.focuses.first { $0.id == id })
        let harness = TimelinePointerHarness(model: model, zoom: 1)
        defer { harness.close() }
        let right = TimelineViewportView.timeOrigin + (original.editingStart + original.duration) * 120
        try harness.mouse(.leftMouseDown, x: right + 2, y: 48)
        try harness.mouse(.leftMouseDragged, x: right - 118, y: 48)
        try harness.mouse(.leftMouseUp, x: right - 118, y: 48)
        let changed = try #require(model.edit.focuses.first { $0.id == id })
        #expect(changed.timelineStart == original.timelineStart)
        #expect(abs(changed.duration - (original.duration - 1)) < 0.000001)
        #expect(model.error == nil)
        let saved = try EditStorage.load(in: model.entry.url, document: model.entry.document)
        #expect(saved.focuses.first { $0.id == id }?.duration == changed.duration)
        model.undo(); #expect(model.edit.focuses.first { $0.id == id } == original)
    }

    @Test func extremelyZoomedOutMediaSupportsBodyMoveAndBothTrimHandles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        let original = model.edit
        let id = try #require(original.clips.first?.id)
        let harness = TimelinePointerHarness(model: model, zoom: -8)
        defer { harness.close() }
        let head = TimelineViewportView.timeOrigin
        // 4 秒视频在该缩放下不足 1pt；从 44pt 外观的中央拖动必须移动素材，不能误裁剪。
        try harness.mouse(.leftMouseDown, x: head + 22, y: 48)
        try harness.mouse(.leftMouseDragged, x: head + 34, y: 48)
        #expect(harness.view.dragGhostVisible)
        try harness.mouse(.leftMouseUp, x: head + 34, y: 48)
        let moved = try #require(model.edit.clips.first { $0.id == id })
        // 12pt 指针移动先抵扣 8pt 阻力，余下 4pt 在该缩放下对应 512 / 30 秒。
        #expect(abs((moved.timelineStart ?? 0) - 512.0 / 30) < 0.000001)
        #expect(moved.duration == original.clips[0].duration)
        #expect(!harness.view.dragGhostVisible)
        model.undo(); harness.sync(); #expect(model.edit == original)

        try harness.mouse(.leftMouseDown, x: head + 3, y: 48)
        try harness.mouse(.leftMouseDragged, x: head + 7, y: 48)
        try harness.mouse(.leftMouseUp, x: head + 7, y: 48)
        let leading = try #require(model.edit.clips.first { $0.id == id })
        #expect(leading.duration == VideoEdit.minimumClipDuration)
        #expect(abs((leading.timelineStart ?? 0) + leading.duration - 4) < 0.000001)
        model.undo(); harness.sync(); #expect(model.edit == original)

        try harness.mouse(.leftMouseDown, x: head + 46, y: 48)
        try harness.mouse(.leftMouseDragged, x: head + 42, y: 48)
        try harness.mouse(.leftMouseUp, x: head + 42, y: 48)
        let trailing = try #require(model.edit.clips.first { $0.id == id })
        #expect(trailing.duration == VideoEdit.minimumClipDuration)
        #expect(trailing.timelineStart == original.clips[0].timelineStart)
        #expect(trailing.sourceStart == original.clips[0].sourceStart)
        #expect(model.error == nil)
    }

    @Test func returningABlockToItsOriginalRowCancelsTheReorderPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        model.seek(1); model.addFocus()
        let original = model.edit
        let harness = TimelinePointerHarness(model: model, zoom: 0)
        defer { harness.close() }
        let middle = TimelineViewportView.timeOrigin + 120
        try harness.mouse(.leftMouseDown, x: middle, y: 48)
        try harness.mouse(.leftMouseDragged, x: middle, y: 120)
        #expect(harness.view.dragGhostVisible)
        try harness.mouse(.leftMouseDragged, x: middle, y: 48)
        try harness.mouse(.leftMouseUp, x: middle, y: 48)
        #expect(model.edit.layerOrder == original.layerOrder)
        #expect(model.edit == original)
        #expect(!harness.view.dragGhostVisible)
    }

    @Test func draggingTheHeaderShowsALiftedBlockAndKeepsHorizontalTimingAndScroll() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        model.seek(1); model.split()
        let original = model.edit
        let harness = TimelinePointerHarness(model: model, zoom: 4)
        defer { harness.close() }
        let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                         wheel1: 0, wheel2: -360, wheel3: 0))
        scroll.flags = []
        harness.view.scrollWheel(with: try #require(NSEvent(cgEvent: scroll)))
        try harness.mouse(.mouseMoved, x: TimelineViewportView.timeOrigin + 240, y: 48)
        let scrolledTime = try #require(model.skimPosition)
        #expect(scrolledTime > 0.25)

        try harness.mouse(.leftMouseDown, x: 24, y: 48)
        try harness.mouse(.leftMouseDragged, x: 24, y: 113)
        #expect(harness.view.dragGhostVisible)
        for _ in 0..<5 { harness.view.advanceAutoScroll() }
        try harness.mouse(.leftMouseUp, x: 24, y: 113)
        #expect(!harness.view.dragGhostVisible)
        #expect(model.edit.clips == original.clips)
        #expect(model.edit.orderedLayerIDs == Array(original.orderedLayerIDs.reversed()))
        try harness.mouse(.mouseMoved, x: TimelineViewportView.timeOrigin + 240, y: 48)
        #expect(model.skimPosition == scrolledTime)
    }

    @Test func shrinkingTheLastBlockKeepsTheScrolledViewportAndDoesNotBounceBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        let id = try #require(model.edit.clips.first?.id)
        let harness = TimelinePointerHarness(model: model, zoom: 3)
        defer { harness.close() }
        let head = TimelineViewportView.timeOrigin, scale = 480.0
        let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                         wheel1: 0, wheel2: -1320, wheel3: 0))
        scroll.flags = []
        harness.view.scrollWheel(with: try #require(NSEvent(cgEvent: scroll)))
        let probeX = head + 40
        try harness.mouse(.mouseMoved, x: probeX, y: 48)
        let originalProbeTime = try #require(model.skimPosition)
        // 时间线只到内容结尾再留 48 点：滚到底时视口起点由视口宽度决定，这里按实际起点推算块的末端位置。
        let viewportStart = originalProbeTime - 40 / scale
        #expect(viewportStart > 1.5 && viewportStart < 4)

        // 视口已靠近末尾；末尾从 4 秒缩到 3 秒时，普通范围夹取会把它强制推回左侧。
        // 拖动和松手都必须保留这个起点，鼠标位移才能始终只表示 1 秒的裁剪量。
        let right = head + (4 - viewportStart) * scale
        try harness.mouse(.leftMouseDown, x: right + 2, y: 48)
        try harness.mouse(.leftMouseDragged, x: right + 2 - scale, y: 48)
        #expect(abs(model.edit.duration - 3) < 0.000001)
        try harness.mouse(.leftMouseUp, x: right + 2 - scale, y: 48)
        let trimmed = try #require(model.edit.clips.first { $0.id == id })
        #expect(abs(trimmed.duration - 3) < 0.000001)
        #expect(trimmed.timelineStart == 0)
        #expect(model.error == nil)
        try harness.mouse(.mouseMoved, x: probeX, y: 48)
        #expect(model.skimPosition == originalProbeTime)
        #expect(harness.view.skimmerVisible)
    }

    @Test func mouseHoverPreviewsWithoutMovingThePlayheadAndExitRestoresIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        model.seek(0.5)
        let harness = TimelinePointerHarness(model: model, zoom: 0)
        defer { harness.close() }
        try harness.mouse(.mouseMoved, x: TimelineViewportView.timeOrigin + 180, y: 48)
        #expect(harness.view.skimmerVisible)
        #expect(model.skimPosition == 3)
        #expect(model.position == 0.5)
        try await waitForTimelinePointer { abs(model.player.currentTime().seconds - 3) < 0.01 }
        #expect(model.position == 0.5)
        try harness.mouse(.mouseExited, x: -1, y: 48)
        #expect(!harness.view.skimmerVisible)
        #expect(model.skimPosition == nil)
        #expect(model.position == 0.5)
        try await waitForTimelinePointer { abs(model.player.currentTime().seconds - 0.5) < 0.01 }
    }

    @Test func movingScreenDoesNotSnapToItsFollowingFocusOnRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        let screenID = try #require(model.edit.clips.first?.id)
        model.seek(0.05); model.addFocus()
        let focusID = try #require(model.selectedFocus)
        #expect(model.edit.focuses.first { $0.id == focusID }?.targetClipID == screenID)
        #expect(model.edit.orderedLayerIDs == [focusID, screenID])
        model.selectClip(screenID)
        let harness = TimelinePointerHarness(model: model, zoom: 0, snapping: true)
        defer { harness.close() }
        let center = TimelineViewportView.timeOrigin + 120
        // 松手前会再次求值。关联聚焦随动到 1.05 秒后，不能成为素材自身的新吸附目标。
        try harness.mouse(.leftMouseDown, x: center, y: 90)
        try harness.mouse(.leftMouseDragged, x: center + 68, y: 90)
        #expect(model.edit.clips.first { $0.id == screenID }?.timelineStart == 1)
        try harness.mouse(.leftMouseUp, x: center + 68, y: 90)
        #expect(model.edit.clips.first { $0.id == screenID }?.timelineStart == 1)
        let followingStart = try #require(model.edit.focuses.first { $0.id == focusID }?.timelineStart)
        #expect(abs(followingStart - 1.05) < 0.000001)
        #expect(model.position == 0.05)
    }

    @Test func stationaryHoverTracksShiftScrollingWithoutMovingThePlayhead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        model.seek(0.5)
        let harness = TimelinePointerHarness(model: model, zoom: 3)
        defer { harness.close() }
        try harness.mouse(.mouseMoved, x: TimelineViewportView.timeOrigin + 480, y: 48)
        #expect(model.skimPosition == 1)
        #expect(harness.view.skimmerVisible)
        let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                         wheel1: -128, wheel2: 0, wheel3: 0))
        scroll.flags = .maskShift
        // 没有第二次 mouseMoved：滚动自身必须按保留的鼠标位置重新计算预览时间。
        harness.view.scrollWheel(with: try #require(NSEvent(cgEvent: scroll)))
        #expect(model.skimPosition == 38.0 / 30)
        #expect(model.position == 0.5)
        #expect(harness.view.skimmerVisible)
        try await waitForTimelinePointer { abs(model.player.currentTime().seconds - 38.0 / 30) < 0.01 }
        #expect(model.position == 0.5)
        try harness.mouse(.mouseExited, x: -1, y: 48)
        #expect(model.skimPosition == nil)
    }

    private func makeTimelinePointerModel(root: URL) async throws -> VideoEditorModel {
        _ = NSApplication.shared
        let url = try await makeEditorFixture(root: root)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        await model.open()
        do {
            try await waitForTimelinePointer { model.ready && !model.loading && model.player.currentItem?.status == .readyToPlay }
            return model
        } catch { model.close(); throw error }
    }

    private func waitForTimelinePointer(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TimelinePointerCheckError.timeout
    }
}

private enum TimelinePointerCheckError: Error { case timeout }

/// 直接向测试进程自己的 NSView 发送事件，不控制桌面，也不依赖用户鼠标位置或系统输入权限。
@MainActor
private final class TimelinePointerHarness {
    let model: VideoEditorModel
    let viewport: TimelineViewport
    let view: TimelineViewportView
    let window: NSWindow

    init(model: VideoEditorModel, zoom: Double, snapping: Bool = false) {
        self.model = model
        viewport = TimelineViewport(); viewport.zoom = zoom; viewport.snapping = snapping
        view = TimelineViewportView(model: model, viewport: viewport)
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 250)
        window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        sync()
    }

    func sync() {
        view.update(edit: model.edit, analysis: model.analysis, selection: model.selectedClipIDs,
                    primary: model.selectedClip, focus: model.selectedFocus, mask: model.selectedMask, text: model.selectedText, caption: model.selectedCaption, zoom: viewport.zoom, fit: 1)
    }

    func mouse(_ type: NSEvent.EventType, x: Double, y: Double) throws {
        let location = view.convert(CGPoint(x: x, y: y), to: nil)
        let event: NSEvent
        if type == .mouseExited {
            event = try #require(NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                       trackingNumber: 0, userData: nil))
        } else {
            event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                   clickCount: 1, pressure: 1))
        }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .mouseMoved: view.mouseMoved(with: event)
        case .mouseExited: view.mouseExited(with: event)
        default: Issue.record("测试不支持该鼠标事件")
        }
        sync()
    }

    func close() {
        view.detach(); window.contentView = nil; window.close()
    }
}

extension WindowLifecycleTests {
    @Test func rightClickOnASplittableBlockOffersSplitAtClickAndPlayhead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        let harness = TimelinePointerHarness(model: model, zoom: 0)
        defer { harness.close() }
        let id = try #require(model.edit.clips.first?.id)
        // 素材 4 秒，从起点算 2 秒处右键：两侧各 2 秒，可以分割。
        let x = TimelineViewportView.timeOrigin + 2 * 60
        let location = harness.view.convert(CGPoint(x: x, y: 49), to: nil as NSView?)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                                   windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(harness.view.menu(for: event))
        let here = try #require(menu.items.first { $0.title.hasPrefix("在此处分割") })
        let clicked = try #require(here.representedObject as? Double)
        #expect(here.isEnabled)
        #expect(abs(clicked - 2) < 0.02)
        #expect(model.selectedClip == id)
        let action = try #require(here.action)
        #expect(NSApplication.shared.sendAction(action, to: here.target, from: here))
        harness.sync()
        #expect(model.edit.clips.count == 2)
        let head = try #require(model.edit.clips.first { $0.id == id })
        #expect(abs(head.duration - 2) < 0.02)
        // 播放头在 0 秒：块起点处不能分割，菜单项禁用。
        model.seek(0)
        let again = try #require(harness.view.menu(for: event))
        #expect(again.items.first { $0.title == "在播放头分割" }?.isEnabled == false)
    }
}

extension WindowLifecycleTests {
    /// 新加镜头后把块（整体或右缘）拖到视口最右侧并触发自动滚动，不能抛出异常，成片必须保持合法。
    @Test(arguments: [1.0, 3.0]) func draggingAFocusBlockToTheFarRightEdgeStaysValid(zoom: Double) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        model.seek(1); model.addFocus()
        let id = try #require(model.selectedFocus)
        let original = try #require(model.edit.focuses.first { $0.id == id })
        let harness = TimelinePointerHarness(model: model, zoom: zoom)
        defer { harness.close() }
        let scale = 60 * pow(2, zoom)
        let left = TimelineViewportView.timeOrigin + original.editingStart * scale
        try harness.mouse(.leftMouseDown, x: left + 20, y: 48)
        try harness.mouse(.leftMouseDragged, x: 990, y: 48)
        for _ in 0..<60 { harness.view.advanceAutoScroll() }
        try harness.mouse(.leftMouseDragged, x: 999, y: 48)
        try harness.mouse(.leftMouseUp, x: 999, y: 48)
        let moved = try #require(model.edit.focuses.first { $0.id == id })
        #expect(moved.duration > 0 && moved.editingStart + moved.duration <= model.edit.duration + 0.001)
        #expect(model.error == nil)

        harness.sync()
        let right = TimelineViewportView.timeOrigin + (moved.editingStart + moved.duration) * scale
        try harness.mouse(.leftMouseDown, x: min(990, right - 2), y: 48)
        try harness.mouse(.leftMouseDragged, x: 990, y: 48)
        for _ in 0..<60 { harness.view.advanceAutoScroll() }
        try harness.mouse(.leftMouseDragged, x: 999, y: 48)
        try harness.mouse(.leftMouseUp, x: 999, y: 48)
        let stretched = try #require(model.edit.focuses.first { $0.id == id })
        #expect(stretched.duration > 0 && stretched.editingStart + stretched.duration <= model.edit.duration + 0.001)
        #expect(model.error == nil)
    }
}

extension WindowLifecycleTests {
    /// 镜头拖到铺满整段录制后，属性面板里"起点"滑块的范围退化为一个点；面板必须照常显示，不能因 NaN 几何抛异常。
    @Test func focusPanelSurvivesAFocusThatFillsTheWholeRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        model.seek(1); model.addFocus()
        let id = try #require(model.selectedFocus)
        model.commit { edit in
            edit.dragFocus(id: id, edge: .leading, delta: -100)
            edit.dragFocus(id: id, edge: .trailing, delta: 100)
        }
        let focus = try #require(model.edit.focuses.first { $0.id == id })
        let bounds = try #require(model.edit.focusBounds(for: id))
        #expect(abs(focus.editingStart - bounds.lowerBound) < 0.000001)
        #expect(abs(focus.editingStart + focus.duration - bounds.upperBound) < 0.000001)

        // "自动镜头参数"默认收起；这里要数全部滑块，先按用户展开过的状态来。
        let expandedKey = "editor.focus.autoParametersExpanded"
        let previous = UserDefaults.standard.object(forKey: expandedKey)
        UserDefaults.standard.set(true, forKey: expandedKey)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: expandedKey) } else { UserDefaults.standard.removeObject(forKey: expandedKey) } }
        let host = NSHostingView(rootView: FocusPanel(model: model).frame(width: 300))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 1200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let calipers = allSubviews(of: host).compactMap { $0 as? CaliperView }
        #expect(calipers.count >= 8)
        for caliper in calipers {
            caliper.layoutSubtreeIfNeeded()
            #expect(caliper.x(for: caliper.value).isFinite)
        }
        #expect(calipers.contains { $0.configuration.range.upperBound == $0.configuration.range.lowerBound })
        #expect(model.error == nil)
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(of: $0) }
    }
}

extension WindowLifecycleTests {
    /// 右键菜单提供"重命名…"；改名后块标题、菜单表头与保存的工程同步，留空恢复默认名称。
    @Test func blockContextMenuOffersRenameAndTitlesFollowTheModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        model.seek(1); model.addFocus()
        let focusID = try #require(model.selectedFocus)
        let clipID = try #require(model.edit.clips.first?.id)
        let harness = TimelinePointerHarness(model: model, zoom: 0)
        defer { harness.close() }
        func menu(atRow y: Double) throws -> NSMenu {
            let location = harness.view.convert(CGPoint(x: TimelineViewportView.timeOrigin + 2 * 60, y: y), to: nil as NSView?)
            let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                                       windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            return try #require(harness.view.menu(for: event))
        }
        let clipMenu = try menu(atRow: 90)
        let rename = try #require(clipMenu.items.first { $0.title == "重命名…" })
        #expect(rename.representedObject as? UUID == clipID)
        #expect(clipMenu.items.first?.title.hasPrefix("录制画面 01") == true)

        harness.view.renameBlock(clipID, to: " 开场 ")
        harness.sync()
        #expect(model.edit.clips.first?.title == "开场")
        #expect(try menu(atRow: 90).items.first?.title.hasPrefix("开场 · ") == true)
        let saved = try EditStorage.load(in: model.entry.url, document: model.entry.document)
        #expect(saved.clips.first?.title == "开场")

        harness.view.renameBlock(focusID, to: "放大标题")
        harness.sync()
        #expect(try menu(atRow: 48).items.first?.title.hasPrefix("放大标题 · ") == true)

        harness.view.renameBlock(clipID, to: "")
        harness.sync()
        #expect(model.edit.clips.first?.title == nil)
        #expect(try menu(atRow: 90).items.first?.title.hasPrefix("录制画面 01") == true)
        model.undo(); harness.sync()
        #expect(model.edit.clips.first?.title == "开场")
    }
}


extension WindowLifecycleTests {
    /// 在镜头行空白处拖出范围就新建一个跟随指针的手动镜头；行下方空白也可以；拖得太短不建。
    @Test func draggingAcrossEmptyFocusRowOnlySeeksAndNeverCreatesAShot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        model.seek(1); model.addFocus()
        let existing = try #require(model.selectedFocus)
        let harness = TimelinePointerHarness(model: model, zoom: 1)
        defer { harness.close() }
        let head = TimelineViewportView.timeOrigin
        // 镜头行（第 0 行，y = 48）里 3.3 → 3.9 秒的空白：按下定位、拖动不建镜头也不弹确认。
        try harness.mouse(.leftMouseDown, x: head + 3.3 * 120, y: 48)
        #expect(abs(model.position - 3.3) < 0.02)
        try harness.mouse(.leftMouseDragged, x: head + 3.9 * 120, y: 48)
        try harness.mouse(.leftMouseUp, x: head + 3.9 * 120, y: 48)
        #expect(model.edit.focuses.count == 1 && model.pendingFocus == nil)
        #expect(model.selectedFocus == existing)
        // 所有行下方的空白同样只定位。
        let belowRows = 28 + Double(model.edit.timelineRows.count) * 42 + 20
        try harness.mouse(.leftMouseDown, x: head + 0.5 * 120, y: belowRows)
        try harness.mouse(.leftMouseDragged, x: head + 1.5 * 120, y: belowRows)
        try harness.mouse(.leftMouseUp, x: head + 1.5 * 120, y: belowRows)
        #expect(model.edit.focuses.count == 1 && model.pendingFocus == nil)
        #expect(abs(model.position - 0.5) < 0.02)
        #expect(model.error == nil)
        // 右键菜单“在此处添加聚焦”仍然可用。
        model.requestAddFocus(start: 3.3, duration: 2)
        #expect(model.edit.focuses.count == 2)
    }
}


extension WindowLifecycleTests {
    /// 片段右键菜单里有"在此处添加聚焦"，落点已有镜头时触发的是确认而不是直接添加。
    @Test func clipContextMenuOffersAddingAFocusAtTheClickedTime() async throws {
        let defaults = UserDefaults(suiteName: "caplo.tests.focus-menu." + UUID().uuidString)!
        VideoEditorModel.defaults = defaults
        defer { VideoEditorModel.defaults = .standard }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        model.seek(1); model.addFocus()
        let harness = TimelinePointerHarness(model: model, zoom: 1)
        defer { harness.close() }
        let head = TimelineViewportView.timeOrigin
        // 录制画面在第 1 行（y = 90），右键落在 2.5 秒处。
        let location = harness.view.convert(CGPoint(x: head + 2.5 * 120, y: 90), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0, windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(harness.view.menu(for: event))
        let item = try #require(menu.items.first { $0.title.hasPrefix("在此处添加聚焦") })
        #expect(item.title.contains(TimelineTime.code(2.5)))
        // 2.5 秒起的 2 秒和已有的 1–3 秒镜头重叠：先问，不直接加。
        _ = item.target?.perform(item.action, with: item)
        #expect(model.pendingFocus != nil && model.edit.focuses.count == 1)
        model.confirmPendingFocus(suppressFurtherPrompts: false)
        #expect(model.edit.focuses.count == 2)
        let added = try #require(model.edit.focuses.last)
        #expect(abs((added.timelineStart ?? -1) - 2.5) < 0.000001 && abs(added.duration - 1.5) < 0.000001)
    }
}

extension WindowLifecycleTests {
    /// 拖遮罩块的右边缘应当只缩短它，而且改的是源素材时间（不能被"固定到成片时间"），
    /// 一次拖动只记一个撤销步骤，落盘后再读回来一致。
    @Test func draggingAMaskBlockTrailingEdgeShrinksItInSourceTime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        model.seek(1)
        let id = try #require(model.addMask())
        let original = try #require(model.edit.mask(id: id))
        #expect(original.timelineStart == nil && abs(original.start - 1) < 0.001)
        let harness = TimelinePointerHarness(model: model, zoom: 1)
        defer { harness.close() }
        // 遮罩行在最上面：第一行的 y 落在 48。
        let right = TimelineViewportView.timeOrigin + (original.start + original.duration) * 120
        try harness.mouse(.leftMouseDown, x: right + 2, y: 48)
        try harness.mouse(.leftMouseDragged, x: right - 60, y: 48)
        try harness.mouse(.leftMouseUp, x: right - 60, y: 48)
        let changed = try #require(model.edit.mask(id: id))
        #expect(changed.start == original.start)
        #expect(changed.timelineStart == nil, "遮罩被固定到了成片时间，后续剪辑就不跟着内容走了")
        #expect(abs(changed.duration - (original.duration - 0.5)) < 0.000001, "拖后时长是 \(changed.duration)")
        #expect(model.error == nil)
        let saved = try EditStorage.load(in: model.entry.url, document: model.entry.document)
        #expect(saved.mask(id: id)?.duration == changed.duration && saved.schemaVersion <= VideoEdit.writtenSchemaVersion)
        model.undo(); harness.sync()
        #expect(model.edit.mask(id: id) == original)
    }

    /// 点遮罩块要选中它（而不是选中聚焦或片段），删除只删这一条。
    @Test func clickingAMaskBlockSelectsItAndDeleteRemovesOnlyThatMask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        model.seek(0.5); let first = try #require(model.addMask())
        model.seek(2.5); let second = try #require(model.addMask())
        model.selectedMask = nil
        let harness = TimelinePointerHarness(model: model, zoom: 1)
        defer { harness.close() }
        // 新加的遮罩排在最上面，所以先加的那条在第二行（y 落在 90）。
        let center = TimelineViewportView.timeOrigin + 1.0 * 120
        try harness.mouse(.leftMouseDown, x: center, y: 90)
        try harness.mouse(.leftMouseUp, x: center, y: 90)
        #expect(model.selectedMask == first && model.selectedFocus == nil && model.selectedMediaID == nil)
        model.deleteSelection()
        #expect(model.edit.maskList.map(\.id) == [second] && model.selectedMask == nil)
        #expect(model.error == nil)
    }
}

extension WindowLifecycleTests {
    /// 拖文字块的右边缘只缩短它、只改源时间，一次拖动一个撤销步骤，落盘后读回来一致。
    @Test func draggingATextBlockTrailingEdgeShrinksItInSourceTime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        model.seek(0.5)
        let id = try #require(model.addText(start: 0.5, duration: 3, preset: .title, text: "标题"))
        let original = try #require(model.edit.text(id: id))
        #expect(original.timelineStart == nil)
        let harness = TimelinePointerHarness(model: model, zoom: 1)
        defer { harness.close() }
        let right = TimelineViewportView.timeOrigin + (original.start + original.duration) * 120
        try harness.mouse(.leftMouseDown, x: right + 2, y: 48)
        try harness.mouse(.leftMouseDragged, x: right - 60, y: 48)
        try harness.mouse(.leftMouseUp, x: right - 60, y: 48)
        let changed = try #require(model.edit.text(id: id))
        #expect(changed.start == original.start && changed.timelineStart == nil)
        #expect(abs(changed.duration - (original.duration - 0.5)) < 0.000001, "拖后时长是 \(changed.duration)")
        #expect(model.error == nil)
        let saved = try EditStorage.load(in: model.entry.url, document: model.entry.document)
        #expect(saved.text(id: id)?.duration == changed.duration && saved.schemaVersion <= VideoEdit.writtenSchemaVersion)
        model.undo(); harness.sync()
        #expect(model.edit.text(id: id) == original)
    }

    /// 文字与遮罩各自选中、各自删除，互不干扰。
    @Test func textAndMaskSelectionsDoNotCollide() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        model.seek(0.5)
        let mask = try #require(model.addMask())
        #expect(model.selectedMask == mask && model.selectedText == nil)
        let text = try #require(model.addText(start: 0.5, duration: 2, preset: .subtitle, text: "副标题"))
        #expect(model.selectedText == text && model.selectedMask == nil)
        // 选中文字时删除只删文字，遮罩留着。
        model.deleteSelection()
        #expect(model.edit.textList.isEmpty && model.edit.maskList.map(\.id) == [mask])
        #expect(model.error == nil)
    }
}

extension WindowLifecycleTests {
    /// 字幕轨不进 layerOrder，是时间线自己插的一条固定轨；点它要能选中、拖右边缘只改这一句的源时间。
    @Test func captionTrackSelectsAndTrimsInSourceTime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        model.commit { edit in
            edit.captionList = [CaptionCue(sourceStart: 0.5, sourceEnd: 2.5, text: "把留白调到四十")]
        }
        let id = try #require(model.edit.captionList.first?.id)
        let harness = TimelinePointerHarness(model: model, zoom: 1)
        defer { harness.close() }

        // 字幕轨插在所有媒体行之上，所以是第一行（y 落在 48）。
        let center = TimelineViewportView.timeOrigin + 1.5 * 120
        try harness.mouse(.leftMouseDown, x: center, y: 48)
        try harness.mouse(.leftMouseUp, x: center, y: 48)
        #expect(model.selectedCaption == id, "点字幕块没有选中它")
        #expect(model.selectedFocus == nil && model.selectedMediaID == nil)

        let right = TimelineViewportView.timeOrigin + 2.5 * 120
        try harness.mouse(.leftMouseDown, x: right + 2, y: 48)
        try harness.mouse(.leftMouseDragged, x: right - 60, y: 48)
        try harness.mouse(.leftMouseUp, x: right - 60, y: 48)
        let changed = try #require(model.edit.caption(id: id))
        #expect(changed.sourceStart == 0.5 && changed.timelineStart == nil)
        #expect(abs(changed.sourceEnd - 2.0) < 0.000001, "拖后结束在源 \(changed.sourceEnd) 秒")
        #expect(model.error == nil)
        model.undo(); harness.sync()
        #expect(model.edit.caption(id: id)?.sourceEnd == 2.5)
    }
}

extension WindowLifecycleTests {
    /// 工程里带着原素材域的自动镜头时，同一次 commit 里既要展开图层又要加叠加层，两边不能互相踩。
    /// （真正让用户撞上"版本不支持"的是关掉自动聚焦后重开的那条路径，
    /// 见 `addingAMaskAfterReopeningWithAutomaticFocusOffDoesNotFailValidation`。）
    @Test func addingOverlaysToARecordingWithAutomaticFocusesSucceeds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        // 自动镜头：源素材域，timelineStart 为空。
        model.commit { $0.focuses = [FocusSegment(start: 0.5, duration: 1.5, x: 0.5, y: 0.5, automatic: true)] }
        #expect(model.error == nil)

        model.seek(1)
        let mask = model.addMask()
        #expect(mask != nil, "加遮罩失败：\(model.error ?? "无错误")")
        #expect(model.error == nil, "加遮罩报了错：\(model.error ?? "")")
        #expect(model.edit.maskList.count == 1 && model.edit.schemaVersion <= VideoEdit.writtenSchemaVersion)

        let text = model.addText(start: 1, duration: 2, preset: .title, text: "标题")
        #expect(text != nil && model.error == nil, "加文字失败：\(model.error ?? "")")
        #expect(model.edit.schemaVersion <= VideoEdit.writtenSchemaVersion)

        model.commit { $0.captionList = [CaptionCue(sourceStart: 0, sourceEnd: 2, text: "一句话")] }
        #expect(model.error == nil, "加字幕失败：\(model.error ?? "")")
        #expect(model.edit.schemaVersion <= VideoEdit.writtenSchemaVersion)

        // 落盘再读回来，三层都还在。
        let saved = try EditStorage.load(in: model.entry.url, document: model.entry.document)
        #expect(saved.maskList.count == 1 && saved.textList.count == 1 && saved.captionList.count == 1)
    }
}

extension WindowLifecycleTests {
    /// 片尾附近复制叠加层：副本要被夹在素材范围内，而不是越界之后整笔回滚弹「版本不支持」。
    @Test func duplicatingOverlaysNearTheEndOfTheMaterialStaysInRange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        let total = model.entry.document.duration

        let mask = try #require(model.addMask(start: total - 0.1, duration: 2))
        model.duplicateSelection()
        #expect(model.error == nil, "复制遮罩报了错：\(model.error ?? "")")
        #expect(model.edit.maskList.count == 2)
        #expect(model.edit.maskList.allSatisfy { $0.start + $0.duration <= total + 0.001 })
        #expect(model.selectedMask != mask, "选中项没有跟到副本上")

        let text = try #require(model.addText(start: total - 0.2, duration: 3, preset: .title, text: "片尾"))
        model.duplicateSelection()
        #expect(model.error == nil, "复制文字报了错：\(model.error ?? "")")
        #expect(model.edit.textList.count == 2)
        #expect(model.edit.textList.allSatisfy { $0.start + $0.duration <= total + 0.001 })
        #expect(model.selectedText != text)
    }

    /// 选中一句字幕按 ⌘D，复制的必须是这句字幕，绝不能去复制录制画面。
    @Test func duplicatingASelectedCaptionDoesNotTouchTheVideoClips() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        model.commit { $0.captionList = [CaptionCue(sourceStart: 0.5, sourceEnd: 1.5, text: "一句话",
                                                    words: [CaptionWord(start: 0.5, end: 1.5, text: "一句话")])] }
        let clipsBefore = model.edit.clips
        model.selectedCaption = model.edit.captionList.first?.id
        model.selectedMask = nil; model.selectedText = nil; model.selectedFocus = nil
        model.duplicateSelection()
        #expect(model.error == nil)
        #expect(model.edit.captionList.count == 2, "字幕没有被复制")
        #expect(model.edit.clips == clipsBefore, "录制画面被动了：从 \(clipsBefore.count) 块变成 \(model.edit.clips.count) 块")
        // 词表跟着副本一起挪，否则高亮会和句子错开。
        let copy = try #require(model.edit.captionList.last)
        #expect(copy.words?.first?.start == copy.sourceStart)
    }

    /// 选中遮罩 / 文字时按 ⌘B，不能去切用户的录像；选中字幕时切的是那一句。
    @Test func splittingRespectsWhichKindOfBlockIsSelected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        model.seek(2)
        let clipsBefore = model.edit.clips

        _ = model.addMask(start: 1, duration: 2)
        #expect(!model.canSplit(at: 2), "选中遮罩时「分割」应当不可用")
        model.split(at: 2)
        #expect(model.edit.clips == clipsBefore, "选中遮罩时分割切开了录制画面")

        model.selectedMask = nil
        _ = model.addText(start: 1, duration: 2, preset: .title, text: "标题")
        #expect(!model.canSplit(at: 2), "选中文字时「分割」应当不可用")
        model.split(at: 2)
        #expect(model.edit.clips == clipsBefore, "选中文字时分割切开了录制画面")

        model.clearSelection()
        model.commit { $0.captionList = [CaptionCue(sourceStart: 0.5, sourceEnd: 3.5, text: "把留白调到四十")] }
        model.selectedCaption = model.edit.captionList.first?.id
        #expect(model.canSplit(at: 2), "选中字幕时应当可以分割这一句")
        model.split(at: 2)
        #expect(model.error == nil)
        #expect(model.edit.captionList.count == 2, "字幕没有被切成两句")
        #expect(model.edit.clips == clipsBefore, "切字幕时把录制画面也切了")
    }

    /// 时间线空白处不给加叠加层，而且要给一句看得懂的提示，不是静默建一个看不见的遮罩。
    @Test func addingOverlaysInATimelineGapExplainsWhyItRefuses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        // 把画面块往右挪，前面留出一段空白。
        model.commit { edit in
            edit.materializeLayers()
            edit.clips[0].timelineStart = 2
        }
        #expect(model.error == nil)
        #expect(model.edit.clip(atTimeline: 0.5) == nil, "没造出空白，这条测试就测不到东西")
        #expect(model.addMask(start: 0.5, duration: 2) == nil)
        #expect(model.error?.contains("播放头不在任何录制画面上") == true, "提示是：\(model.error ?? "无")")
        #expect(model.edit.maskList.isEmpty)
    }
}

extension WindowLifecycleTests {
    /// 选中态必须是"只有一项"。每个分支各清各的写法漏过一次：
    /// 先点字幕块再点遮罩块，`selectedCaption` 还留着，按删除键删掉的是那句字幕而不是遮罩。
    @Test func selectingOneKindOfBlockClearsEveryOtherKind() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        model.commit { $0.captionList = [CaptionCue(sourceStart: 0.2, sourceEnd: 1.2, text: "一句话")] }
        _ = model.addMask(start: 0.2, duration: 1)
        _ = model.addText(start: 0.2, duration: 1, preset: .title, text: "标题")
        let harness = TimelinePointerHarness(model: model, zoom: 1)
        defer { harness.close() }

        /// 点某一行的块，返回当时的四个选中项。
        func click(row: Int) throws {
            let x = TimelineViewportView.timeOrigin + 0.7 * 120
            let y = 48.0 + Double(row) * 42
            try harness.mouse(.leftMouseDown, x: x, y: y)
            try harness.mouse(.leftMouseUp, x: x, y: y)
        }
        func selectedCount() -> Int {
            [model.selectedMask != nil, model.selectedText != nil, model.selectedCaption != nil,
             model.selectedFocus != nil, model.selectedMediaID != nil].filter { $0 }.count
        }
        // 逐行点过去，每一次都只能有一项被选中。
        for row in 0..<4 {
            try click(row: row)
            #expect(selectedCount() <= 1, "点第 \(row) 行之后同时选中了 \(selectedCount()) 项")
        }
        // 具体走一遍那条漏过的顺序：先点字幕块、再点遮罩块、然后删除，删掉的必须是遮罩。
        let captionRow = try #require((0..<4).first { row in
            model.clearSelection(); try? click(row: row); return model.selectedCaption != nil
        })
        let maskRow = try #require((0..<4).first { row in
            model.clearSelection(); try? click(row: row); return model.selectedMask != nil
        })
        model.clearSelection()
        try click(row: captionRow)
        #expect(model.selectedCaption != nil)
        try click(row: maskRow)
        #expect(model.selectedMask != nil && model.selectedCaption == nil, "选了遮罩之后字幕的选中态还留着")
        model.deleteSelection()
        #expect(model.edit.maskList.isEmpty, "删除没有删掉遮罩")
        #expect(model.edit.captionList.count == 1, "删除把字幕也删了")
    }
}

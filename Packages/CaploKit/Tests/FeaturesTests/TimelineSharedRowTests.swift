import AppKit
import AVFoundation
import EditingCore
import ProjectKit
import Testing
@testable import Features

extension WindowLifecycleTests {
    @Test func aBlockCanJoinAnotherRowWithoutChangingItsTimeAndUndoRestoresSeparateRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeSharedRowModel(root: root)
        defer { model.close() }
        let original = model.edit, ids = original.clips.map(\.id)
        let harness = SharedTimelineHarness(model: model)
        defer { harness.close() }
        try harness.joinThirdBlockToFirstRow()
        #expect(model.edit.timelineRows == [[ids[0], ids[2]], [ids[1]]])
        #expect(model.edit.clips == original.clips)
        #expect(model.history.canUndo)
        let saved = try EditStorage.load(in: model.entry.url, document: model.entry.document)
        #expect(saved.timelineRows == model.edit.timelineRows)
        #expect(saved.clips == original.clips)
        model.undo(); harness.sync()
        #expect(model.edit == original)
    }

    @Test func aSharedBlockCanDetachAtARowBoundaryAndUndoRestoresItsGroup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeSharedRowModel(root: root)
        defer { model.close() }
        let ids = model.edit.clips.map(\.id)
        let harness = SharedTimelineHarness(model: model)
        defer { harness.close() }
        try harness.joinThirdBlockToFirstRow()
        let grouped = model.edit
        let center = TimelineViewportView.timeOrigin + 2.8 * 60
        try harness.mouse(.leftMouseDown, x: center, y: 49)
        try harness.mouse(.leftMouseDragged, x: center, y: 72)
        try harness.mouse(.leftMouseUp, x: center, y: 72)
        #expect(model.edit.timelineRows == [[ids[0]], [ids[2]], [ids[1]]])
        #expect(model.edit.clips == grouped.clips)
        #expect(try EditStorage.load(in: model.entry.url, document: model.entry.document).timelineRows == model.edit.timelineRows)
        model.undo(); harness.sync()
        #expect(model.edit == grouped)
    }

    @Test func selectingAndTrimmingDifferentBlocksInOneRowOnlyChangesTheHitBlock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeSharedRowModel(root: root)
        defer { model.close() }
        let ids = model.edit.clips.map(\.id)
        let harness = SharedTimelineHarness(model: model)
        defer { harness.close() }
        try harness.joinThirdBlockToFirstRow()
        let original = model.edit
        let origin = TimelineViewportView.timeOrigin
        try harness.mouse(.leftMouseDown, x: origin + 24, y: 49)
        try harness.mouse(.leftMouseUp, x: origin + 24, y: 49)
        #expect(model.selectedClip == ids[0])
        try harness.mouse(.leftMouseDown, x: origin + 50, y: 49)
        try harness.mouse(.leftMouseDragged, x: origin + 44, y: 49)
        try harness.mouse(.leftMouseUp, x: origin + 44, y: 49)
        #expect(abs(try #require(model.edit.clips.first { $0.id == ids[0] }).duration - 0.7) < 0.000001)
        #expect(model.edit.clips.first { $0.id == ids[1] } == original.clips[1])
        #expect(model.edit.clips.first { $0.id == ids[2] } == original.clips[2])
        let afterFirstTrim = model.edit

        try harness.mouse(.leftMouseDown, x: origin + 168, y: 49)
        try harness.mouse(.leftMouseUp, x: origin + 168, y: 49)
        #expect(model.selectedClip == ids[2])
        try harness.mouse(.leftMouseDown, x: origin + 194, y: 49)
        try harness.mouse(.leftMouseDragged, x: origin + 188, y: 49)
        try harness.mouse(.leftMouseUp, x: origin + 188, y: 49)
        #expect(abs(try #require(model.edit.clips.first { $0.id == ids[2] }).duration - 0.7) < 0.000001)
        #expect(model.edit.clips.first { $0.id == ids[0] } == afterFirstTrim.clips.first { $0.id == ids[0] })
        #expect(model.edit.clips.first { $0.id == ids[1] } == original.clips[1])
        #expect(model.edit.timelineRows == original.timelineRows)
    }

    @Test func movementInsideTheDeadZoneDoesNotCreateAnEditOrRewriteTheSavedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeSharedRowModel(root: root)
        defer { model.close() }
        let original = model.edit
        let file = model.entry.url.appendingPathComponent("edits.json")
        let savedBytes = try Data(contentsOf: file)
        let harness = SharedTimelineHarness(model: model)
        defer { harness.close() }
        let center = TimelineViewportView.timeOrigin + 24
        try harness.mouse(.leftMouseDown, x: center, y: 49)
        try harness.mouse(.leftMouseDragged, x: center + 6, y: 52)
        #expect(!harness.view.dragGhostVisible)
        try harness.mouse(.leftMouseUp, x: center + 6, y: 52)
        #expect(model.edit == original)
        #expect(model.edit.timelineRows == original.timelineRows)
        #expect(!model.history.canUndo && !model.history.canRedo)
        #expect(try Data(contentsOf: file) == savedBytes)
    }

    @Test func droppingOverlappingMediaIntoOneRowCancelsWithoutSavingAnInvalidGroup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeSharedRowModel(root: root, overlapping: true)
        defer { model.close() }
        let original = model.edit
        let file = model.entry.url.appendingPathComponent("edits.json")
        let savedBytes = try Data(contentsOf: file)
        let harness = SharedTimelineHarness(model: model)
        defer { harness.close() }
        let center = TimelineViewportView.timeOrigin + 0.6 * 60
        try harness.mouse(.leftMouseDown, x: center, y: 91)
        try harness.mouse(.leftMouseDragged, x: center, y: 49)
        #expect(harness.view.dragGhostVisible)
        try harness.mouse(.leftMouseUp, x: center, y: 49)
        #expect(!harness.view.dragGhostVisible)
        #expect(model.edit == original)
        #expect(!model.history.canUndo)
        #expect(try Data(contentsOf: file) == savedBytes)
    }

    @Test func draggingASharedRowHeaderMovesTheWholeRowAndKeepsItsMediaTiming() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeSharedRowModel(root: root)
        defer { model.close() }
        let ids = model.edit.clips.map(\.id)
        let harness = SharedTimelineHarness(model: model)
        defer { harness.close() }
        try harness.joinThirdBlockToFirstRow()
        let original = model.edit
        try harness.mouse(.leftMouseDown, x: 24, y: 49)
        try harness.mouse(.leftMouseDragged, x: 24, y: 113)
        try harness.mouse(.leftMouseUp, x: 24, y: 113)
        #expect(model.edit.timelineRows == [[ids[1]], [ids[0], ids[2]]])
        #expect(model.edit.clips == original.clips)
        model.undo(); #expect(model.edit == original)
    }

    @Test func detachingAtTheCurrentRowsUpperEdgeCanMovePastFormerNeighbors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeSharedRowModel(root: root)
        defer { model.close() }
        let ids = model.edit.clips.map(\.id)
        let harness = SharedTimelineHarness(model: model)
        defer { harness.close() }
        try harness.joinThirdBlockToFirstRow()
        let original = model.edit
        let origin = TimelineViewportView.timeOrigin
        // 目标仍在行 0 的坐标范围，但已进入其上方插入区，不能继续套用原同行的邻块边界。
        try harness.mouse(.leftMouseDown, x: origin + 168, y: 49)
        try harness.mouse(.leftMouseDragged, x: origin + 30, y: 30)
        try harness.mouse(.leftMouseUp, x: origin + 30, y: 30)
        let moved = try #require(model.edit.clips.first { $0.id == ids[2] })
        #expect(abs((moved.timelineStart ?? 0) - 7.0 / 30) < 0.000001)
        #expect(model.edit.timelineRows == [[ids[2]], [ids[0]], [ids[1]]])
        #expect(model.edit.clips.first { $0.id == ids[0] } == original.clips[0])
        #expect(model.edit.clips.first { $0.id == ids[1] } == original.clips[1])
        #expect(moved.duration == original.clips[2].duration)
        model.undo(); #expect(model.edit == original)
    }

    @Test func horizontalMovementFromTheBlockTopDoesNotAccidentallyDetachIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeSharedRowModel(root: root)
        defer { model.close() }
        let ids = model.edit.clips.map(\.id)
        let harness = SharedTimelineHarness(model: model)
        defer { harness.close() }
        try harness.joinThirdBlockToFirstRow()
        let original = model.edit
        let center = TimelineViewportView.timeOrigin + 168
        try harness.mouse(.leftMouseDown, x: center, y: 34)
        try harness.mouse(.leftMouseDragged, x: center - 20, y: 34)
        try harness.mouse(.leftMouseUp, x: center - 20, y: 34)
        let moved = try #require(model.edit.clips.first { $0.id == ids[2] })
        #expect(abs((moved.timelineStart ?? 0) - 2.2) < 0.000001)
        #expect(model.edit.timelineRows == original.timelineRows)
        #expect(model.edit.clips.first { $0.id == ids[0] } == original.clips[0])
        #expect(model.edit.clips.first { $0.id == ids[1] } == original.clips[1])
    }

    @Test func aMenuSelectedBlockRemainsSelectableAndDraggableWhenMinimumWidthsOverlap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeSharedRowModel(root: root)
        defer { model.close() }
        let ids = model.edit.clips.map(\.id)
        let harness = SharedTimelineHarness(model: model)
        defer { harness.close() }
        try harness.joinThirdBlockToFirstRow()
        let original = model.edit
        harness.viewport.zoom = -8; harness.sync()
        let center = TimelineViewportView.timeOrigin + 22
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown,
                                                   location: harness.view.convert(CGPoint(x: center, y: 49), to: nil),
                                                   modifierFlags: [], timestamp: 0, windowNumber: harness.window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(harness.view.menu(for: event))
        // 右键落在块上时同行块列在"同行块"子菜单里；落在空白处则直接就是同行块列表。
        let members = menu.items.first { $0.submenu?.title == "同行块" }?.submenu?.items ?? menu.items
        #expect(Set(members.compactMap { $0.representedObject as? UUID }) == Set([ids[0], ids[2]]))
        let hidden = try #require(members.first { ($0.representedObject as? UUID) == ids[0] })
        let action = try #require(hidden.action)
        #expect(NSApplication.shared.sendAction(action, to: hidden.target, from: hidden))
        harness.sync()
        #expect(model.selectedClip == ids[0])
        // 两块起点只相差不足 1pt，但点击置顶块中央仍应操作菜单刚选定的那一块。
        try harness.mouse(.leftMouseDown, x: center, y: 49)
        try harness.mouse(.leftMouseUp, x: center, y: 49)
        #expect(model.selectedClip == ids[0])
        #expect(model.edit == original)
        try harness.mouse(.leftMouseDown, x: center, y: 49)
        try harness.mouse(.leftMouseDragged, x: center + 12, y: 49)
        try harness.mouse(.leftMouseUp, x: center + 12, y: 49)
        let moved = try #require(model.edit.clips.first { $0.id == ids[0] })
        #expect(model.selectedClip == ids[0])
        #expect(abs((moved.timelineStart ?? 0) - 1.6) < 0.000001)
        #expect(moved.duration == original.clips[0].duration)
        #expect(model.edit.clips.first { $0.id == ids[2] } == original.clips[2])
        #expect(model.edit.timelineRows == original.timelineRows)
    }

    private func makeSharedRowModel(root: URL, overlapping: Bool = false) async throws -> VideoEditorModel {
        _ = NSApplication.shared
        let url = try await makeEditorFixture(root: root)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        await model.open()
        do {
            try await waitForSharedTimeline { model.ready && !model.loading && model.player.currentItem?.status == .readyToPlay }
            var edit = model.edit
            edit.clips = [0.0, overlapping ? 0.2 : 1.2, 2.4].enumerated().map { index, start in
                var clip = VideoClip(sourceStart: Double(index), duration: 0.8)
                clip.timelineStart = start
                return clip
            }
            edit.focuses = []; edit.rowGroups = nil; edit.layerOrder = edit.clips.map(\.id)
            edit.prepareLayerEditing(camera: false, system: false, microphone: false)
            model.commit { $0 = edit }
            model.history = EditHistory()
            model.selectClip(edit.clips[0].id)
            try await waitForSharedTimeline { !model.loading && !model.rebuilding && model.player.currentItem?.status == .readyToPlay }
            return model
        } catch { model.close(); throw error }
    }

    private func waitForSharedTimeline(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SharedTimelineCheckError.timeout
    }
}

private enum SharedTimelineCheckError: Error { case timeout }

/// 真实测试窗口中的直接事件回归；同行选择和拖放由应用自己的命中算法处理。
@MainActor
private final class SharedTimelineHarness {
    let model: VideoEditorModel
    let viewport = TimelineViewport()
    let view: TimelineViewportView
    let window: NSWindow

    init(model: VideoEditorModel) {
        self.model = model
        viewport.snapping = false
        view = TimelineViewportView(model: model, viewport: viewport)
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 300)
        window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        sync()
    }

    func joinThirdBlockToFirstRow() throws {
        let center = TimelineViewportView.timeOrigin + 2.8 * 60
        try mouse(.leftMouseDown, x: center, y: 133)
        try mouse(.leftMouseDragged, x: center, y: 49)
        try mouse(.leftMouseUp, x: center, y: 49)
    }

    func sync() {
        view.update(edit: model.edit, analysis: model.analysis, selection: model.selectedClipIDs,
                    primary: model.selectedClip, focus: model.selectedFocus, zoom: viewport.zoom, fit: 1)
    }

    func mouse(_ type: NSEvent.EventType, x: Double, y: Double) throws {
        let event = try #require(NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: x, y: y), to: nil),
                                                   modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: Issue.record("测试不支持该鼠标事件")
        }
        sync()
    }

    func close() { view.detach(); window.contentView = nil; window.close() }
}


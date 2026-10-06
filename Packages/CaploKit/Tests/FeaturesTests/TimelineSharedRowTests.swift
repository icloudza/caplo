import AppKit
import AVFoundation
import EditingCore
import ProjectKit
import Testing
@testable import Features

extension WindowLifecycleTests {

}

extension WindowLifecycleTests {
    /// 点行内空白挪播放头并**取消选中**（2026-09-14 起）；行头（轨道图标那一列）照旧选中并可整行拖。
    /// 一行现在装的是整条轨，"点空白就选中这一行的第一块"会选到八竿子打不着的东西；
    /// 而选中之后没有一处能取消，面板就一直卡在那一块上。
    @Test func clickingEmptySpaceInARowSeeksAndClearsTheSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeEmptyClickModel(root: root)
        defer { model.close() }
        let ids = model.edit.clips.map(\.id)
        let harness = EmptyClickHarness(model: model)
        defer { harness.close() }

        // 先选中第一块，再点空白，选中应当被清掉。
        let origin = TimelineViewportView.timeOrigin
        try harness.mouse(.leftMouseDown, x: origin + 20, y: 49)
        try harness.mouse(.leftMouseUp, x: origin + 20, y: 49)
        #expect(model.selectedClip == ids[0])
        let before = model.edit

        // 三块之间留着空档：点在空档上只该把播放头挪过去。
        let gap = origin + 1.0 * 60
        try harness.mouse(.leftMouseDown, x: gap, y: 49)
        try harness.mouse(.leftMouseUp, x: gap, y: 49)
        #expect(model.selectedClip == nil && model.selectedClipIDs.isEmpty, "点空白没有取消选中")
        #expect(abs(model.position - 1.0) < 0.05, "点空白没有把播放头挪过去（现在在 \(model.position)）")
        #expect(model.edit == before, "点空白改动了工程")
        #expect(!model.history.canUndo)

        // 所有行下方的大片空白同样定位并取消选中。
        try harness.mouse(.leftMouseDown, x: origin + 20, y: 49)
        try harness.mouse(.leftMouseUp, x: origin + 20, y: 49)
        #expect(model.selectedClip == ids[0])
        // 旧写法点在 y = 230，落在导航条那一带、根本没进轨道区，断言"选中不变"因此空转。
        let belowRows = 28 + Double(model.edit.timelineRows.count) * 42 + 12
        try harness.mouse(.leftMouseDown, x: origin + 1.6 * 60, y: belowRows)
        try harness.mouse(.leftMouseUp, x: origin + 1.6 * 60, y: belowRows)
        #expect(model.selectedClip == nil, "点所有行下方的空白没有取消选中")
        #expect(abs(model.position - 1.6) < 0.05, "点行下空白没有定位（现在在 \(model.position)）")

        // 行头仍然选中这一行并允许整行拖动。
        try harness.mouse(.leftMouseDown, x: 20, y: 49)
        try harness.mouse(.leftMouseUp, x: 20, y: 49)
        #expect(model.selectedClip != nil, "点行头应当选中这一行的块")
        #expect(model.error == nil)
    }

    private func makeEmptyClickModel(root: URL) async throws -> VideoEditorModel {
        _ = NSApplication.shared
        let url = try await makeEditorFixture(root: root)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        await model.open()
        for _ in 0..<300 {
            if model.ready && !model.loading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        var edit = model.edit
        edit.prepareLayerEditing(camera: false, system: false, microphone: false)
        // 三块之间各留 0.6 秒空档，好点在"行内空白"上。
        edit.clips = [0.0, 1.4, 2.8].enumerated().map { index, start in
            var clip = VideoClip(sourceStart: Double(index) * 0.8, duration: 0.8)
            clip.timelineStart = start
            return clip
        }
        edit.focuses = []; edit.rowGroups = nil; edit.layerOrder = edit.clips.map(\.id)
        model.commit { $0 = edit }
        model.history = EditHistory()
        model.clearSelection()
        for _ in 0..<200 {
            if !model.loading && !model.rebuilding { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        return model
    }
}

@MainActor
private final class EmptyClickHarness {
    let model: VideoEditorModel
    let viewport: TimelineViewport
    let view: TimelineViewportView
    let window: NSWindow
    init(model: VideoEditorModel) {
        self.model = model
        viewport = TimelineViewport(); viewport.zoom = 0; viewport.snapping = false
        view = TimelineViewportView(model: model, viewport: viewport)
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 400)
        window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        sync()
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
        default: view.mouseUp(with: event)
        }
        sync()
    }
    func close() { view.detach(); window.contentView = nil; window.close() }
}

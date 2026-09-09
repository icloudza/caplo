import AppKit
import AVFoundation
import EditingCore
import ProjectKit
import Testing
@testable import Features

extension WindowLifecycleTests {
    /// 拖动一帧的代价。用户报过"拖动时有点卡"，量出来是每帧 90 毫秒——60fps 只有 16.7 毫秒的预算。
    /// 花销几乎全在绘制上：逐块新建 SF Symbol 图像、逐块重新排版标题、逐块新建贝塞尔路径、
    /// 逐块造一个辅助功能元素。缓存与合批之后降到 10 毫秒以内。
    /// 这条测试盯着这个预算，别让它慢慢涨回去。
    @Test func draggingABlockCostsBoundedWorkPerFrame() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeBusyEditorModel(root: root)
        defer { model.close() }
        let harness = DragCostHarness(model: model)
        defer { harness.close() }

        #expect(model.error == nil, "夹具没建起来：\(model.error ?? "")")
        let id = try #require(model.edit.clips.dropFirst().first?.id)
        let block = try #require(model.edit.timelineBlockRanges[id])
        let row = try #require(harness.view.rowIndexForTesting(of: id))
        let y = 28 + Double(row) * 44 + 22
        let x = TimelineViewportView.timeOrigin + (block.lowerBound + block.upperBound) / 2 * 60

        try harness.mouse(.leftMouseDown, x: x, y: y)
        // 先跑几帧热身，再计时。
        for step in 0..<10 { try harness.mouse(.leftMouseDragged, x: x + Double(step), y: y); harness.sync() }
        var eventCost = 0.0, updateCost = 0.0, drawCost = 0.0
        let started = Date()
        let frames = 60
        for step in 0..<frames {
            var mark = Date()
            try harness.mouse(.leftMouseDragged, x: x + 10 + Double(step) * 0.5, y: y)
            eventCost += Date().timeIntervalSince(mark); mark = Date()
            harness.refresh()
            updateCost += Date().timeIntervalSince(mark); mark = Date()
            harness.paint()
            drawCost += Date().timeIntervalSince(mark)
        }
        let elapsed = Date().timeIntervalSince(started)
        let eventEach = eventCost / Double(frames) * 1000, drawEach = drawCost / Double(frames) * 1000
        print(String(format: "拖动分解：鼠标 %.2f / 刷新 %.2f / 绘制 %.2f 毫秒每帧",
                     eventEach, updateCost / Double(frames) * 1000, drawEach))
        #expect(eventEach < 4, "模型侧一帧要 \(String(format: "%.2f", eventEach)) 毫秒")
        #expect(drawEach < 11, "绘制一帧要 \(String(format: "%.2f", drawEach)) 毫秒")
        try harness.mouse(.leftMouseUp, x: x + 40, y: y)
        // 再量一次拖文字块：这条路会走到"换合成 + 定位播放器"，与拖画面块完全不同。
        if let textID = model.edit.textList.first?.id, let textRow = harness.view.rowIndexForTesting(of: textID),
           let range = model.edit.timelineBlockRanges[textID] {
            let ty = 28 + Double(textRow) * 44 + 22
            let tx = TimelineViewportView.timeOrigin + (range.lowerBound + range.upperBound) / 2 * 60
            try harness.mouse(.leftMouseDown, x: tx, y: ty)
            for step in 0..<5 { try harness.mouse(.leftMouseDragged, x: tx + Double(step), y: ty); harness.sync() }
            var textEvent = 0.0, textDraw = 0.0
            for step in 0..<30 {
                var mark = Date()
                try harness.mouse(.leftMouseDragged, x: tx + 6 + Double(step) * 0.5, y: ty)
                textEvent += Date().timeIntervalSince(mark); mark = Date()
                harness.sync()
                textDraw += Date().timeIntervalSince(mark)
            }
            try harness.mouse(.leftMouseUp, x: tx + 24, y: ty)
            print(String(format: "拖文字块：鼠标 %.2f / 刷新绘制 %.2f 毫秒每帧", textEvent / 30 * 1000, textDraw / 30 * 1000))
            #expect(textEvent / 30 * 1000 < 4, "拖文字块的模型开销偏高")
        }
        let perFrame = elapsed / Double(frames) * 1000
        print("拖动每帧 \(String(format: "%.2f", perFrame)) 毫秒（\(frames) 帧共 \(String(format: "%.0f", elapsed * 1000)) 毫秒）")
        #expect(perFrame < 13, "拖动一帧要 \(String(format: "%.2f", perFrame)) 毫秒，60fps 只有 16.7 毫秒的预算")
    }

    /// 一个"什么都有"的工程：多段画面 + 摄像头 + 两条声音 + 镜头 + 遮罩 + 文字 + 字幕 + 定格卡段。
    func makeBusyEditorModel(root: URL, captions: Int = 300) async throws -> VideoEditorModel {
        _ = NSApplication.shared
        let url = try await makeEditorFixture(root: root, audio: true)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        await model.open()
        for _ in 0..<300 {
            if model.ready && !model.loading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        var edit = model.edit
        edit.prepareLayerEditing(camera: false, system: true, microphone: true)
        // 素材只有几秒，但成片可以由同一段素材反复拼出来——这才像真实工程：块多、时间线长。
        let source = max(0.5, model.entry.document.duration)
        let piece = min(0.5, source / 2)
        let clipCount = 40
        edit.clips = (0..<clipCount).map { number in
            var clip = VideoClip(sourceStart: 0, duration: piece)
            clip.timelineStart = Double(number) * piece
            return clip
        }
        for role in [TimelineMedia.system, .microphone] {
            edit.setMediaClips(role, (0..<clipCount).map { number in
                var clip = VideoClip(sourceStart: 0, duration: piece)
                clip.timelineStart = Double(number) * piece
                return clip
            })
        }
        let span = Double(clipCount) * piece
        edit.focuses = (0..<12).map { number in
            var focus = FocusSegment(start: 0, duration: span / 24, x: 0.4, y: 0.6, scale: 1.6)
            focus.timelineStart = Double(number) * span / 12
            return focus
        }
        for number in 0..<10 {
            var mask = MaskSegment(start: 0, duration: span / 24, x: 0.4, y: 0.5, width: 0.2, height: 0.1)
            mask.timelineStart = Double(number) * span / 10
            mask.positionKeys = (0...4).map { MaskPointKeyframe(time: Double($0) * span / 120, x: 0.2 + Double($0) * 0.1, y: 0.5) }
            edit.addMask(mask)
        }
        for number in 0..<12 {
            var text = TextSegment(start: 0, duration: span / 30, text: "第 \(number + 1) 段")
            text.timelineStart = Double(number) * span / 12
            text.layout = number % 4 == 0 ? .splitRight : .overlay
            edit.addText(text)
        }
        edit.captionList = (0..<captions).map { number in
            var cue = CaptionCue(sourceStart: 0, sourceEnd: min(source, span / Double(captions) * 0.8),
                                 text: "第 \(number + 1) 句字幕")
            cue.timelineStart = Double(number) * span / Double(captions)
            return cue
        }
        edit.normalizeTimelineRows()
        model.commit { $0 = edit }
        model.history = EditHistory()
        for _ in 0..<200 {
            if !model.loading && !model.rebuilding { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        return model
    }
}

@MainActor
private final class DragCostHarness {
    let model: VideoEditorModel
    let viewport: TimelineViewport
    let view: TimelineViewportView
    let window: NSWindow

    init(model: VideoEditorModel) {
        self.model = model
        viewport = TimelineViewport(); viewport.zoom = 0; viewport.snapping = true
        view = TimelineViewportView(model: model, viewport: viewport)
        view.frame = CGRect(x: 0, y: 0, width: 1200, height: 320)
        window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        sync()
    }
    func sync() { refresh(); paint() }
    func refresh() {
        view.update(edit: model.edit, analysis: model.analysis, selection: model.selectedClipIDs,
                    primary: model.selectedClip, focus: model.selectedFocus, mask: model.selectedMask,
                    text: model.selectedText, caption: model.selectedCaption, zoom: viewport.zoom, fit: 1)
    }
    func paint() { view.displayIfNeeded() }
    func mouse(_ type: NSEvent.EventType, x: Double, y: Double) throws {
        let location = view.convert(CGPoint(x: x, y: y), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: Issue.record("不支持的事件")
        }
    }
    func close() { view.detach(); window.contentView = nil; window.close() }
}

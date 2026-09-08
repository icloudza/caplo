import AppKit
import AVFoundation
import CoreImage
import EditingCore
import ExportKit
import ProjectKit
import RenderKit
import Testing
@testable import Features

extension WindowLifecycleTests {
    /// 真正向本进程时间线拖双边，核对跨片段后不回弹、只保存一次且撤销还原关联。
    @Test func focusHandlesCrossSeveralClipsAndKeepPlaybackItemAndUndo() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root)
        let document = try ProjectStorage.load(url)
        var edit = VideoEdit(duration: 4)
        edit.prepareLayerEditing(camera: false, system: false, microphone: false)
        let first = edit.clips[0].id
        let splitResult = edit.splitMedia(.screen, id: first, at: 1)
        let tail = try #require(splitResult)
        _ = edit.splitMedia(.screen, id: tail, at: 2)
        try EditStorage.save(edit, in: url, document: document)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: document))
        defer { model.close() }
        await model.open()
        try await waitForCrossFocus { !model.loading && !model.rebuilding && model.player.currentItem?.status == .readyToPlay }
        model.selectClip(first); model.seek(0.2); model.addFocus()
        try await waitForCrossFocus { !model.rebuilding && model.player.currentItem?.status == .readyToPlay }
        let id = try #require(model.selectedFocus), original = model.edit
        let item = model.player.currentItem
        let viewport = TimelineViewport(); viewport.zoom = 1; viewport.snapping = false
        let view = TimelineViewportView(model: model, viewport: viewport)
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 350)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { view.detach(); window.contentView = nil; window.close() }
        func sync() {
            view.update(edit: model.edit, analysis: model.analysis, selection: model.selectedClipIDs,
                        primary: model.selectedClip, focus: model.selectedFocus, zoom: 1, fit: 1)
        }
        func drag(from: Double, to: Double) throws {
            let row = try #require(model.edit.timelineRows.firstIndex { $0.contains(id) })
            let y = 28.0 + Double(row) * 42 + 20
            for (type, x) in [(NSEvent.EventType.leftMouseDown, from), (.leftMouseDragged, to), (.leftMouseUp, to)] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: x, y: y), to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                switch type { case .leftMouseDown: view.mouseDown(with: event); case .leftMouseDragged: view.mouseDragged(with: event); default: view.mouseUp(with: event) }
                sync()
            }
        }
        sync()
        let origin = TimelineViewportView.timeOrigin
        try drag(from: origin + 120 - 2, to: origin + 700)
        let extended = try #require(model.edit.focuses.first { $0.id == id })
        #expect(extended.targetClipID == nil && extended.followsTimeline == true)
        #expect(abs(extended.editingStart + extended.duration - 4) < 0.00001)
        #expect(model.edit.duration == 4 && model.player.currentItem === item && !model.rebuilding)
        try drag(from: origin + 0.2 * 120 + 2, to: origin)
        let full = try #require(model.edit.focuses.first { $0.id == id })
        #expect(full.editingStart == 0 && full.duration == 4)
        // 右边往左缩短也仍可用；收回单素材内不隐式重绑，避免随后移动被另一片段牵走。
        try drag(from: origin + 4 * 120 - 2, to: origin + 0.5 * 120 - 2)
        #expect(abs((model.edit.focuses.first { $0.id == id }?.duration ?? 0) - 0.5) < 0.00001)
        #expect(model.edit.focuses.first { $0.id == id }?.targetClipID == nil)
        #expect(model.error == nil)
        #expect(try EditStorage.load(in: url, document: document) == model.edit)
        model.undo(); model.undo(); model.undo()
        #expect(model.edit == original)
        model.redo(); model.redo(); model.redo()
        #expect(model.error == nil && model.edit.duration == 4)
    }

    /// 不同源时段拥有相反点击目标。实际静帧、播放器指令和 MP4 必须在剪切 / 空隙 / 保持后仍一致。
    @Test func crossClipFocusPreviewPlaybackAndExportAgreeAcrossCutsGapsAndHold() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeFocusPatternFixture(root: root)
        let document = try ProjectStorage.load(url)
        var edit = VideoEdit(duration: 0)
        func clip(_ source: Double, _ start: Double, _ duration: Double, media: Double? = nil) -> VideoClip {
            var value = VideoClip(sourceStart: source, duration: duration)
            value.timelineStart = start; value.mediaDuration = media; return value
        }
        edit.clips = [clip(0, 0, 1), clip(2, 1, 1), clip(0, 3, 1), clip(3, 4, 2, media: 1)]
        edit.prepareLayerEditing(camera: false, system: false, microphone: false)
        edit.pointer = nil
        var focus = FocusSegment(start: 0, duration: 6, x: 0.5, y: 0.5)
        focus.timelineStart = 0; focus.followsTimeline = true
        edit.focuses = [focus]
        try EditStorage.save(edit, in: url, document: document)
        let item = try await ProjectMedia.playerItem(url: url, document: document, levels: edit.audio, edit: edit)
        let instruction = try #require(item.videoComposition?.instructions.first as? SceneInstruction)
        #expect(instruction.edit.focuses[0].path != nil)
        #expect(edit.focuses[0].path == nil)
        let compiled = edit.resolvingTimelineFocus(events: try EditStorage.events(in: url, document: document))
        #expect(instruction.edit == compiled)
        #expect(SceneEvaluator.focus(edit: compiled, time: 2.5).scale == 1)
        #expect(SceneEvaluator.focus(edit: compiled, time: 1.5).x > 0.65)
        #expect(SceneEvaluator.focus(edit: compiled, time: 3.5).x < 0.35)
        #expect(SceneEvaluator.focus(edit: compiled, time: 5).x == SceneEvaluator.focus(edit: compiled, time: 5.2).x)

        let output = root.appendingPathComponent("cross-clip-focus.mp4")
        try await ProjectMedia.export(url: url, document: document, levels: edit.audio, destination: output, edit: edit, longEdge: 320) { _ in }
        let asset = AVURLAsset(url: output)
        #expect(abs(try await asset.load(.duration).seconds - 6) < 0.035)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let playback = AVAssetImageGenerator(asset: item.asset)
        playback.videoComposition = item.videoComposition
        playback.requestedTimeToleranceBefore = .zero; playback.requestedTimeToleranceAfter = .zero
        let renderer = EditorPreviewRenderer()
        do {
            for (time, red) in [(0.6, true), (1.5, false), (3.5, true), (4.7, true), (5.2, true)] {
                let stamp = CMTime(seconds: time, preferredTimescale: 30)
                let poster = try await renderer.render(url: url, document: document, edit: edit, time: time)
                let actual = try await generator.image(at: stamp).image
                let playing = try await playback.image(at: stamp).image
                for image in [poster, actual, playing] {
                    let color = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.sRGB))
                    #expect(red ? color.redComponent > color.blueComponent + 0.5 : color.blueComponent > color.redComponent + 0.5)
                }
            }
            // 同一 renderer 在同一时刻切换固定 / 跟随，必须更新规划缓存，即使光标模块关闭。
            var fixed = edit
            fixed.focuses[0].followsTimeline = false; fixed.focuses[0].x = 0.75
            for (input, red) in [(fixed, false), (edit, true)] {
                let image = try await renderer.render(url: url, document: document, edit: input, time: 0.6)
                let color = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.sRGB))
                #expect(red ? color.redComponent > color.blueComponent + 0.5 : color.blueComponent > color.redComponent + 0.5)
            }
            await renderer.close()
        } catch { await renderer.close(); throw error }
        // 仅规划和导出不能把生成路径写回用户文件。
        #expect(try EditStorage.load(in: url, document: document).focuses == edit.focuses)
    }

    private func makeFocusPatternFixture(root: URL) async throws -> URL {
        let url = try ProjectStorage.create(in: root, name: "跨片段聚焦测试")
        let path = "Media/pattern.mov"
        let writer = try AVAssetWriter(outputURL: url.appendingPathComponent(path), fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(input); #expect(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for second in 0..<4 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            #expect(CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer) == kCVReturnSuccess)
            let pixel = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let bytes = try #require(CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to: UInt8.self))
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            for y in 0..<180 { for x in 0..<320 {
                let offset = y * stride + x * 4
                bytes[offset] = x < 160 ? 0 : 255; bytes[offset + 1] = 0
                bytes[offset + 2] = x < 160 ? 255 : 0; bytes[offset + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            #expect(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(second), timescale: 1)))
        }
        writer.endSession(atSourceTime: CMTime(value: 4, timescale: 1)); input.markAsFinished()
        await writer.finishWriting(); #expect(writer.status == .completed)
        let events = [PointerSample(time: 0, x: 0.25, y: 0.5, kind: .click),
                      PointerSample(time: 1, x: 0.75, y: 0.5, kind: .click),
                      PointerSample(time: 2, x: 0.75, y: 0.5, kind: .click),
                      PointerSample(time: 3, x: 0.25, y: 0.5, kind: .click)]
        let eventPath = "Events/pointer.json"
        try JSONEncoder().encode(events).write(to: url.appendingPathComponent(eventPath))
        var segment = SegmentRecord(id: 0, duration: 4, files: [.screen: path]); segment.eventsPath = eventPath
        try ProjectStorage.commit(segment, to: url); try ProjectStorage.complete(url)
        return url
    }

    private func waitForCrossFocus(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CrossFocusError.timeout
    }
    private enum CrossFocusError: Error { case timeout }
}

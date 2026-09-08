import AVFoundation
import AppKit
import SwiftUI
import CoreImage
import Testing
import ProjectKit
import EditingCore
import ExportKit
@testable import Features

extension WindowLifecycleTests {
    @Test func cameraPresentationUpdatesAndCancelledDragKeepPlayerAndSavedLayout() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root)
        var document = try ProjectStorage.load(url)
        // 重用合成视频作为第二来源，测试模型生命周期，不访问摄像头硬件。
        document.segments[0].files[.camera] = document.segments[0].files[.screen]
        try ProjectStorage.save(document, to: url)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: document))
        defer { model.close() }
        await model.open()
        try await waitForEditor { !model.loading && model.player.currentItem?.status == .readyToPlay && model.canvas.frame != nil }
        let item = try #require(model.player.currentItem)
        let original = model.edit
        let pixels = try #require(model.canvas.snapshot()?.dataProvider?.data)
        model.beginInteraction()
        model.edit.camera?.x = 0; model.edit.camera?.size = 0.45
        model.previewChanged()
        try await waitForEditor { model.canvas.snapshot()?.dataProvider?.data.map { !CFEqual($0, pixels) } == true }
        model.cancelInteraction()
        try await waitForEditor { model.canvas.snapshot()?.dataProvider?.data.map { CFEqual($0, pixels) } == true }
        #expect(model.edit == original && model.player.currentItem === item)
        model.commit { $0.camera?.enabled = false }
        #expect(model.player.currentItem === item)
        #expect(try EditStorage.load(in: url, document: document).camera?.enabled == false)
        model.undo()
        #expect(model.edit == original && model.player.currentItem === item)
        model.redo()
        #expect(model.edit.camera?.enabled == false)
    }

    @Test func timelinePanelClampsHeightAndVerticalScrollKeepsAudioReachable() async throws {
        _ = NSApplication.shared
        let key = "editor.timelineHeight", previous = UserDefaults.standard.object(forKey: "editor.timelineHeight")
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set(5000.0, forKey: key)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root, audio: true)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        defer { model.close() }
        let host = NSHostingView(rootView: VideoEditorView(model: model) {}.frame(width: 1040, height: 720))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1040, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await waitForEditor { model.ready && !model.loading }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let view = try #require(findTimeline(in: host))
        #expect(view.bounds.height < 400 && view.bounds.height > 200)
        let frame = view.convert(view.bounds, to: host)
        #expect(frame.minY >= -1 && frame.maxY <= host.bounds.height + 1)
        UserDefaults.standard.set(180.0, forKey: key)
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        #expect(view.bounds.height < 140)
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -500, wheel2: 0, wheel3: 0))
        wheel.flags = []
        view.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
        view.displayIfNeeded()
        // 轨头不再放静音 / 独奏按钮：滚动后只需保证视口仍能正常绘制。
        #expect(view.subviews.compactMap { $0 as? NSButton }.isEmpty)
    }

    @Test func independentFocusRowsMoveResizeReorderAndUndo() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        defer { model.close() }
        await model.open()
        try await waitForEditor { !model.loading && model.player.currentItem?.status == .readyToPlay }
        model.seek(1); model.addFocus()
        let focus = try #require(model.selectedFocus), clip = try #require(model.selectedClip)
        #expect(model.edit.orderedLayerIDs.prefix(2) == [focus, clip])
        #expect(model.edit.focuses.first { $0.id == focus }?.targetClipID == clip)
        let original = model.edit
        let viewport = TimelineViewport(); viewport.zoom = 1; viewport.snapping = false
        let view = TimelineViewportView(model: model, viewport: viewport)
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 250)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { view.detach(); window.contentView = nil; window.close() }
        func sync() { view.update(edit: model.edit, analysis: model.analysis, selection: model.selectedClipIDs, primary: model.selectedClip, focus: model.selectedFocus, zoom: 1, fit: 1) }
        func mouse(_ type: NSEvent.EventType, _ x: Double, _ y: Double) throws {
            let event = try #require(NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            switch type { case .leftMouseDown: view.mouseDown(with: event); case .leftMouseDragged: view.mouseDragged(with: event); default: view.mouseUp(with: event) }
            sync()
        }
        sync()
        let head = TimelineViewportView.timeOrigin
        try mouse(.leftMouseDown, head + 180, 48); try mouse(.leftMouseDragged, head + 248, 48); try mouse(.leftMouseUp, head + 248, 48)
        #expect(model.edit.focuses.first { $0.id == focus }?.timelineStart == 1.5)
        model.undo(); sync(); #expect(model.edit == original)
        try await waitForEditor { !model.rebuilding && model.player.currentItem?.status == .readyToPlay }
        let itemBeforeResize = try #require(model.player.currentItem)
        try mouse(.leftMouseDown, head + 359, 48); try mouse(.leftMouseDragged, head + 599, 48); try mouse(.leftMouseUp, head + 599, 48)
        let resizedFocus = try #require(model.edit.focuses.first { $0.id == focus })
        let target = try #require(model.edit.clips.first { $0.id == clip })
        #expect(abs(resizedFocus.editingStart + resizedFocus.duration - ((target.timelineStart ?? 0) + target.duration)) < 0.000001)
        #expect(model.edit.duration == original.duration)
        #expect(model.player.currentItem === itemBeforeResize && !model.rebuilding)
        try model.edit.validate(sourceDuration: model.entry.document.duration)
        #expect(try EditStorage.load(in: url, document: model.entry.document).focuses.first { $0.id == focus } == resizedFocus)
        model.undo(); sync(); #expect(model.edit == original)
        try mouse(.leftMouseDown, 12, 48); try mouse(.leftMouseDragged, 12, 113); try mouse(.leftMouseUp, 12, 113)
        #expect(model.edit.orderedLayerIDs.prefix(2) == [clip, focus])
        #expect(model.edit.focuses == original.focuses)
        model.undo(); sync(); #expect(model.edit == original)
        try mouse(.leftMouseDown, head + 180, 48); try mouse(.leftMouseDragged, head + 240, 48)
        model.cancelInteraction(); #expect(model.edit == original)
    }

    @Test func liveAudioControlsPreservePlaybackAndUndoCancelledAdjustment() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root, audio: true)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        defer { model.close() }
        await model.open()
        try await waitForEditor { !model.loading && model.player.currentItem?.status == .readyToPlay }
        let item = try #require(model.player.currentItem)
        func gain() throws -> Float {
            let parameter = try #require(item.audioMix?.inputParameters.first)
            var start: Float = 0, end: Float = 0, range = CMTimeRange.zero
            #expect(parameter.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range))
            return start
        }
        model.togglePlayback()
        try await waitForEditor { model.playing && model.player.rate == 1 }
        model.beginInteraction(); model.edit.audio.microphone = 0.4; model.previewChanged(); model.endInteraction()
        #expect(model.playing && model.player.rate == 1)
        #expect(try gain() == 0.4)
        model.beginInteraction(); model.edit.audio.microphone = 0.7; model.previewChanged(); model.cancelInteraction()
        #expect(model.edit.audio.microphone == 0.4)
        #expect(try gain() == 0.4)
        // 拖回起始值不产生新命令，但必须恢复播放中的增益。
        model.beginInteraction(); model.edit.audio.microphone = 0.7; model.previewChanged()
        model.edit.audio.microphone = 0.4; model.previewChanged(); model.endInteraction()
        #expect(try gain() == 0.4)
        model.undo()
        #expect(model.edit.audio.microphone == 1)
        #expect(try gain() == 1)
        model.redo()
        #expect(model.playing && model.player.currentItem === item)

        let viewport = TimelineViewport()
        let view = TimelineViewportView(model: model, viewport: viewport)
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 230)
        defer { view.detach() }
        view.update(edit: model.edit, analysis: model.analysis, selection: [], primary: nil, focus: nil, zoom: 0, fit: 0)
        // 静音 / 独奏从工具栏触发，走模型同一入口；没有的音轨不会被改动。
        #expect(!model.audioTracks.contains(.system))
        model.toggleSolo(.system); model.toggleMute(.system)
        #expect(model.edit.audio.solo.isEmpty && model.edit.audio.muted.isEmpty)
        model.toggleSolo(.microphone); model.toggleMute(.microphone)
        #expect(model.edit.audio.solo == [.microphone] && model.edit.audio.muted == [.microphone])
        #expect(try gain() == 0)
        #expect(model.playing && model.player.currentItem === item)
        model.undo()
        #expect(try gain() == 0.4)
        model.pause()
        #expect(model.close())
        let reopened = try EditStorage.load(in: url, document: ProjectStorage.load(url))
        #expect(reopened.audio.solo == [.microphone])
        #expect(reopened.audio.microphone == 0.4)
    }

    @Test func nativeLayersMoveExtendAndPersistWithIndependentAudio() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root, audio: true)
        let document = try ProjectStorage.load(url)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: document))
        defer { model.close() }
        await model.open()
        try await waitForEditor { !model.loading && model.player.currentItem?.status == .readyToPlay }
        model.seek(1); model.split()
        let original = model.edit
        let first = original.clips[0].id, second = original.clips[1].id
        #expect(original.orderedLayerIDs.first == second)
        let viewport = TimelineViewport(); viewport.snapping = false
        let view = TimelineViewportView(model: model, viewport: viewport)
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 250)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { view.detach(); window.contentView = nil; window.close() }
        func sync() { view.update(edit: model.edit, analysis: model.analysis, selection: model.selectedClipIDs, primary: model.selectedClip, focus: model.selectedFocus, zoom: 0, fit: 0) }
        func mouse(_ type: NSEvent.EventType, _ x: Double, _ y: Double) throws {
            let event = try #require(NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            switch type { case .leftMouseDown: view.mouseDown(with: event); case .leftMouseDragged: view.mouseDragged(with: event); default: view.mouseUp(with: event) }; sync()
        }
        sync(); let head = TimelineViewportView.timeOrigin
        try mouse(.leftMouseDown, head + 120, 48); try mouse(.leftMouseDragged, head + 248, 48); try mouse(.leftMouseUp, head + 248, 48)
        #expect(model.edit.clips.first { $0.id == second }?.timelineStart == 3)
        #expect(model.edit.microphoneClips == original.microphoneClips)
        #expect(model.edit.duration == 6)
        model.undo(); sync(); #expect(model.edit == original)
        try mouse(.leftMouseDown, head + 239, 48); try mouse(.leftMouseDragged, head + 359, 48); try mouse(.leftMouseUp, head + 359, 48)
        #expect(model.edit.duration == 6)
        #expect(model.edit.clips.first { $0.id == second }?.mediaDuration == 3)
        model.undo(); sync()
        try mouse(.leftMouseDown, 12, 90); try mouse(.leftMouseDragged, 12, 29); try mouse(.leftMouseUp, 12, 29)
        #expect(model.edit.orderedLayerIDs.first == first)
        #expect(try EditStorage.load(in: url, document: document).layerOrder == model.edit.layerOrder)
        model.undo(); #expect(model.edit == original)
        model.selectedMedia = .microphone; model.selectedMediaID = model.edit.microphoneClips?.first?.id
        model.seek(2); model.split()
        #expect(model.edit.microphoneClips?.count == 2)
        #expect(model.edit.clips == original.clips)
        model.undo(); #expect(model.edit == original)
    }

    @Test func longTimelinePaintIsBoundedAndPlayheadDoesNotRedrawTracks() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try ProjectStorage.create(in: root, name: "长时间线绘制")
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        model.edit.clips = (0..<100_000).map { _ in VideoClip(sourceStart: 0, duration: 1) }
        model.edit.focuses = [FocusSegment(start: 0.2, duration: 0.4, x: 0.5, y: 0.5, automatic: true)]
        let viewport = TimelineViewport()
        let host = NSHostingView(rootView: TimelineViewportBridge(model: model, viewport: viewport))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 230), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let view = try #require(findTimeline(in: host))
        view.displayIfNeeded()
        #expect(view.visibleClipDrawCount < 20)
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -120, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: wheel))
        view.scrollWheel(with: event); view.displayIfNeeded()
        let first = try #require(view.accessibilityChildren()?.first as? NSAccessibilityElement)
        #expect(first.accessibilityLabel()?.hasPrefix("录制画面 01，") == true)
        viewport.fit(duration: model.edit.duration)
        try await Task.sleep(for: .milliseconds(100))
        view.displayIfNeeded()
        #expect(view.visibleClipDrawCount < 500)
        #expect(view.visibleFocusDrawCount < 500)
        let count = view.trackDrawCount
        for frame in 1...30 {
            model.position = Double(frame) / 30
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(100))
        view.displayIfNeeded()
        #expect(view.trackDrawCount == count)
        #expect(view.accessibilityValue() as? String == "00:00:01:00")
    }

    private func findTimeline(in view: NSView) -> TimelineViewportView? {
        if let timeline = view as? TimelineViewportView { return timeline }
        for child in view.subviews { if let result = findTimeline(in: child) { return result } }
        return nil
    }

    /// 与窗口生命周期测试共用串行 Suite，避免两个测试同时改写当前编辑会话。
    @Test func rapidSeekingAndStyleUndoKeepLatestFrameAndPlayerItem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        defer { model.close() }
        await model.open()
        try await waitForEditor { !model.loading && model.player.currentItem?.status == .readyToPlay && model.canvas.frame != nil }
        let original = try #require(model.player.currentItem)
        let padding = model.edit.layout.padding
        model.commit { $0.layout.padding = 60 }
        #expect(model.player.currentItem === original)
        model.undo()
        #expect(model.edit.layout.padding == padding)
        #expect(model.player.currentItem === original)
        model.redo()
        #expect(model.edit.layout.padding == 60)
        #expect(model.player.currentItem === original)

        model.seek(0.5)
        await Task.yield()
        for index in 0..<200 { model.seek(Double(index % 35) / 10) }
        model.seek(2.5)
        try await waitForEditor {
            abs(model.player.currentTime().seconds - 2.5) < 0.01 && model.canvas.snapshot().map(isBlueFrame) == true
        }
        // 等待旧回调排空，确认最终显示和用户定位不会再被较早的 seek 覆盖。
        try await Task.sleep(for: .milliseconds(150))
        #expect(abs(model.position - 2.5) < 0.01)
        #expect(model.player.currentItem === original)
        #expect(model.error == nil)
        model.split()
        model.seek(1.5)
        try await waitForEditor { !model.loading && model.player.currentItem !== original && abs(model.player.currentTime().seconds - 1.5) < 0.01 }
        #expect(model.edit.clips.count == 2)
        try await waitForEditor { model.canvas.snapshot().map { !isBlueFrame($0) } == true }
        let originalPixels = try #require(model.canvas.snapshot()?.dataProvider?.data)
        model.beginInteraction(); model.edit.layout.padding = 90; model.previewChanged()
        try await waitForEditor { model.canvas.snapshot()?.dataProvider?.data.map { !CFEqual($0, originalPixels) } == true }
        model.edit.layout.padding = 60; model.previewChanged(); model.endInteraction()
        // 画布滑块拖回起始值也必须恢复静帧，不能被即时调音路径误判为无需刷新。
        try await waitForEditor { model.canvas.snapshot()?.dataProvider?.data.map { CFEqual($0, originalPixels) } == true }
        #expect(model.close())
        #expect(try EditStorage.load(in: url, document: ProjectStorage.load(url)).clips.count == 2)
    }

    private func waitForEditor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw EditorCheckError.timeout
    }
    private enum EditorCheckError: Error { case timeout }

    private func isBlueFrame(_ image: CGImage) -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(CIImage(cgImage: image), toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return pixel[2] > 150 && pixel[0] < 80
    }

    /// 前两秒红、后两秒蓝，真实编码可检测最终画面，而静态素材只能检测时间数值。
    func makeEditorFixture(root: URL, audio: Bool = false) async throws -> URL {
        let url = try ProjectStorage.create(in: root, name: "编辑性能测试")
        let path = "Media/test.mov"
        let writer = try AVAssetWriter(outputURL: url.appendingPathComponent(path), fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180, AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(input)
        #expect(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for second in 0..<4 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            let pool = try #require(adaptor.pixelBufferPool)
            #expect(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess)
            let pixel = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let base = try #require(CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to: UInt8.self))
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            for y in 0..<180 { for x in 0..<320 {
                let offset = y * stride + x * 4
                base[offset] = second < 2 ? 0 : 255
                base[offset + 1] = 0; base[offset + 2] = second < 2 ? 255 : 0; base[offset + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            #expect(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(second), timescale: 1)))
        }
        writer.endSession(atSourceTime: CMTime(value: 4, timescale: 1)); input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        var files: [MediaRole: String] = [.screen: path]
        if audio {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000))
            buffer.frameLength = buffer.frameCapacity
            let channel = try #require(buffer.floatChannelData?.pointee)
            for sample in 0..<192_000 { channel[sample] = Float(sin(Double(sample) * 440 * 2 * .pi / 48_000)) * 0.1 }
            let audioPath = "Media/microphone.caf"
            let file = try AVAudioFile(forWriting: url.appendingPathComponent(audioPath), settings: format.settings)
            try file.write(from: buffer)
            files[.microphone] = audioPath
        }
        try ProjectStorage.commit(SegmentRecord(id: 0, duration: 4, files: files), to: url)
        try ProjectStorage.complete(url)
        return url
    }
}

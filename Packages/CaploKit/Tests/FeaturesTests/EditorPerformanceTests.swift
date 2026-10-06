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
        // 整条轨现在只占一行，可访问元素跟着可见区间裁剪：只保证第一个是画面块且标签成形，
        // 不再假定它一定是第一段（横向滚过去之后本来就不该再为屏幕外的块建元素）。
        let label = try #require(first.accessibilityLabel())
        #expect(label.hasPrefix("录制画面 ") && label.contains("，起点 "), "标签是 \(label)")
        #expect((view.accessibilityChildren()?.count ?? 0) < 600, "可访问元素没跟着裁剪，一行上万个块会把 VoiceOver 拖垮")
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

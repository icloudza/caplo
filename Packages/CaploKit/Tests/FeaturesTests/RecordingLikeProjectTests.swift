import AVFoundation
import AppKit
import Foundation
import Testing
import EditingCore
import ProjectKit
@testable import Features

/// 尽量接近真实录制的工程：带指针事件，因此 `EditStorage.load` 会用 `AutoFocus.generate`
/// 生成一批 `timelineStart == nil` 的自动镜头。之前所有测试夹具都没有这一条，
/// 于是"添加遮罩报版本不支持"这个 bug 一路绿灯到了用户手上。
extension WindowLifecycleTests {
    @MainActor
    private func makeRecordingLikeProject(root: URL) async throws -> URL {
        let url = try ProjectStorage.create(in: root, name: "像真实录制")
        var document = try ProjectStorage.load(url)
        document.capture = CaptureMetadata(desktopBounds: CGRect(x: 0, y: 0, width: 320, height: 180),
                                           pixelSize: CGSize(width: 320, height: 180), pointPixelScale: 1, pointerEnabled: true)
        try ProjectStorage.save(document, to: url)

        let path = "Media/000000-screen.mov"
        let writer = try AVAssetWriter(outputURL: url.appendingPathComponent(path), fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
        ])
        writer.add(input)
        #expect(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for second in 0..<6 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            let pool = try #require(adaptor.pixelBufferPool)
            #expect(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess)
            #expect(adaptor.append(try #require(buffer), withPresentationTime: CMTime(value: Int64(second), timescale: 1)))
        }
        writer.endSession(atSourceTime: CMTime(value: 6, timescale: 1)); input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)

        // 指针事件：来回移动加两次点击，足够 AutoFocus 生成自动镜头。
        var samples: [PointerSample] = []
        for step in 0..<120 {
            let time = Double(step) / 20
            samples.append(PointerSample(time: time, x: 0.2 + 0.6 * abs(sin(time)), y: 0.5, kind: .move))
        }
        samples.append(PointerSample(time: 1.5, x: 0.7, y: 0.5, kind: .click))
        samples.append(PointerSample(time: 4.0, x: 0.3, y: 0.6, kind: .click))
        // 与录制器同一写法：LZFSE 压缩的事件文件（明文旧格式由跨片段聚焦那组测试覆盖）。
        let eventsPath = "Events/000000." + PointerEventFile.pathExtension
        try PointerEventFile.data(for: samples).write(to: url.appendingPathComponent(eventsPath))

        var record = SegmentRecord(id: 0, duration: 6, files: [.screen: path])
        record.eventsPath = eventsPath
        try ProjectStorage.commit(record, to: url)
        try ProjectStorage.complete(url)
        return url
    }

    /// 画布上的编辑框用 `model.renderEdit` 求相机；它必须是"已经把跟随镜头编译成运镜路径"的那一份，
    /// 也就是画面真正用的那一份。用 `model.edit` 的话，跟随镜头一推近框就和画面分家。
    @Test func modelExposesTheSameResolvedEditThePictureUses() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeRecordingLikeProject(root: root)
        let document = try ProjectStorage.load(url)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: document))
        defer { model.close() }
        await model.open()
        for _ in 0..<300 {
            if model.ready, !model.loading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        // 手动加一个跟随镜头：它在 model.edit 里只有静态相机。
        let focus = try #require(model.addFocus(start: 1, duration: 2))
        await model.setFocusFollowing(focus, enabled: true)
        #expect(model.error == nil)
        let plain = try #require(model.edit.focuses.first { $0.id == focus })
        #expect(plain.followsTimeline == true)

        let resolved = try #require(model.renderEdit.focuses.first { $0.id == focus })
        #expect(resolved.path != nil, "renderEdit 里的跟随镜头没有运镜路径，画布还是会和画面分家")
        // 同一时刻两份数据算出的相机确实不同，说明这个区分不是多余的。
        var worst = 0.0
        for step in 0...20 {
            let time = 1 + Double(step) / 10
            let a = SceneEvaluator.focus(edit: model.edit, time: time)
            let b = SceneEvaluator.focus(edit: model.renderEdit, time: time)
            worst = max(worst, max(abs(a.targetX - b.targetX), abs(a.targetY - b.targetY)))
        }
        #expect(worst > 0.02, "两份数据的相机只差 \(worst)")
        // 只改遮罩时不该重新规划：renderEdit 仍然带着同一条路径。
        _ = model.addMask(start: 1, duration: 1)
        #expect(model.renderEdit.focuses.first { $0.id == focus }?.path == resolved.path)
    }
}

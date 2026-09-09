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
        let eventsPath = "Events/000000.json"
        try JSONEncoder().encode(samples).write(to: url.appendingPathComponent(eventsPath))

        var record = SegmentRecord(id: 0, duration: 6, files: [.screen: path])
        record.eventsPath = eventsPath
        try ProjectStorage.commit(record, to: url)
        try ProjectStorage.complete(url)
        return url
    }

    /// 用户报的原问题：在真实录制上点「添加遮罩」，收到
    /// "编辑数据版本不支持或内容无效，已保留原文件"，遮罩加不进去。
    @Test func addingAMaskToARealRecordingDoesNotFailValidation() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeRecordingLikeProject(root: root)
        let document = try ProjectStorage.load(url)

        // 载入时自动生成的镜头必须存在且在原素材域——这正是触发条件。
        let loaded = try EditStorage.load(in: url, document: document)
        #expect(loaded.focuses.contains { $0.automatic && $0.timelineStart == nil },
                "夹具没有生成自动镜头，这条测试就测不到那个 bug 了")

        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: document))
        defer { model.close() }
        await model.open()
        for _ in 0..<300 {
            if model.ready, !model.loading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.error == nil)

        model.seek(2)
        let mask = model.addMask()
        #expect(mask != nil, "添加遮罩失败：\(model.error ?? "没有错误信息")")
        #expect(model.error == nil, "添加遮罩报了错：\(model.error ?? "")")
        #expect(model.edit.maskList.count == 1)
        #expect(model.edit.schemaVersion <= VideoEdit.writtenSchemaVersion)

        // 文字层与字幕走同一条 commit 路径，一并确认。
        #expect(model.addText(start: 2, duration: 2, preset: .lowerThird, text: "第 2 章") != nil,
                "添加文字失败：\(model.error ?? "")")
        model.commit { $0.captionList = [CaptionCue(sourceStart: 1, sourceEnd: 3, text: "一句话")] }
        #expect(model.error == nil, "添加字幕失败：\(model.error ?? "")")

        // 落盘之后再读回来，三层都在，而且自动镜头没被破坏。
        let saved = try EditStorage.load(in: url, document: document)
        #expect(saved.maskList.count == 1 && saved.textList.count == 1 && saved.captionList.count == 1)
        #expect(saved.schemaVersion <= VideoEdit.writtenSchemaVersion)
        #expect(!saved.focuses.isEmpty)
    }

    /// 用户那台机器上的真正触发条件：**上次会话关掉了「自动聚焦」并存了盘**。
    ///
    /// `focusSpans` 会跳过 `automatic && !automaticFocus` 的镜头，于是 `prepareLayerEditing`
    /// 里的 `materializeFocus` 永远轮不到它们，它们一直留在原素材域。
    /// 结果是此后**每一次** commit 都会再走一遍 `prepareLayerEditing`——包括"添加遮罩"那一次。
    /// 它原本无条件写 `schemaVersion = 6`，把遮罩要求的 7 冲掉，校验当场拒绝、整笔回滚。
    @Test func addingAMaskAfterReopeningWithAutomaticFocusOffDoesNotFailValidation() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeRecordingLikeProject(root: root)
        let document = try ProjectStorage.load(url)

        // 上一次会话：关掉自动聚焦并存盘。
        var stored = try EditStorage.load(in: url, document: document)
        #expect(stored.focuses.contains { $0.automatic && $0.timelineStart == nil })
        stored.automaticFocus = false
        try EditStorage.save(stored, in: url, document: document)

        // 这一次会话：重新打开。自动镜头因为投影不出来，始终留在原素材域。
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: document))
        defer { model.close() }
        await model.open()
        for _ in 0..<300 {
            if model.ready, !model.loading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.error == nil)
        #expect(model.edit.focuses.contains { $0.automatic && $0.timelineStart == nil },
                "自动镜头被展开了，这条测试就测不到那个 bug 了")

        model.seek(2)
        let mask = model.addMask()
        #expect(mask != nil, "添加遮罩失败：\(model.error ?? "没有错误信息")")
        #expect(model.error == nil, "添加遮罩报了错：\(model.error ?? "")")
        #expect(model.edit.schemaVersion <= VideoEdit.writtenSchemaVersion)
        #expect(model.addText(start: 2, duration: 2, preset: .title, text: "标题") != nil,
                "添加文字失败：\(model.error ?? "")")
        model.commit { $0.captionList = [CaptionCue(sourceStart: 1, sourceEnd: 3, text: "一句话")] }
        #expect(model.error == nil, "添加字幕失败：\(model.error ?? "")")

        let saved = try EditStorage.load(in: url, document: document)
        #expect(saved.maskList.count == 1 && saved.textList.count == 1 && saved.captionList.count == 1)
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

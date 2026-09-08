import Foundation
import AVFoundation
import CoreImage
import Testing
import ProjectKit
import ExportKit
import EditingCore
import RenderKit
@testable import CaptureKit

/// 通过真实编码、剪辑和解码链路验证时长、声音、输出尺寸以及共用渲染的像素结果。
@Test @MainActor func editedExportMatchesSharedRendererAndKeepsAudio() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "剪辑与合成测试")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: true, microphone: true, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) {
        writer.ingest(try patternFrame(at: CMTime(seconds: 10, preferredTimescale: 600)), role: .screen)
        writer.ingest(try makeAudio(at: CMTime(seconds: 10, preferredTimescale: 600), duration: 3, channels: 2), role: .systemAudio)
        writer.ingest(try makeAudio(at: CMTime(seconds: 10, preferredTimescale: 600), duration: 3, channels: 1), role: .microphone)
    }
    writer.appendPointer(PointerSample(time: 10.8, x: 0.7, y: 0.3, kind: .click))
    try await writer.finish(at: CMTime(seconds: 13, preferredTimescale: 600))
    try ProjectStorage.complete(url)
    let document = try ProjectStorage.load(url)
    var edit = try EditStorage.load(in: url, document: document)
    #expect(edit.focuses.count == 1)
    _ = edit.split(at: 1); _ = edit.split(at: 2); edit.clips.remove(at: 1)
    edit.layout.ratio = .portrait; edit.layout.padding = 80
    // 镜头的编辑时间与原素材起点故意不同，验证剪辑后手动镜头能进入真实视频合成。
    var manual = FocusSegment(start: 2.2, duration: 0.8, x: 0.6, y: 0.4, scale: 2.2)
    manual.timelineStart = 0.4; edit.focuses.append(manual)
    #expect(abs(SceneEvaluator.focus(edit: edit, time: 0.8).scale - 2.2) < 0.001)
    let (composition, _) = try await ProjectMedia.compose(url: url, document: document, levels: edit.audio, edit: edit)
    #expect(abs(composition.duration.seconds - 2) < 0.01)
    #expect(composition.tracks(withMediaType: .audio).count == 2)
    let item = try await ProjectMedia.playerItem(url: url, document: document, levels: edit.audio, edit: edit)
    #expect(item.videoComposition?.customVideoCompositorClass == VideoCompositor.self)
    let target = root.appendingPathComponent("edited.mp4")
    try await ProjectMedia.export(url: url, document: document, levels: edit.audio, destination: target, edit: edit) { _ in }
    let asset = AVURLAsset(url: target)
    #expect(abs(try await asset.load(.duration).seconds - 2) < 0.08)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    #expect(try await track.load(.naturalSize) == CGSize(width: 1080, height: 1920))
    #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    let exported = try await generator.image(at: CMTime(seconds: 0.8, preferredTimescale: 600)).image
    let source = AVAssetImageGenerator(asset: AVURLAsset(url: try ProjectStorage.mediaURL(document.segments[0].files[.screen]!, in: url)))
    let decoded = try await source.image(at: .zero).image
    let expected = SceneRenderer.frame(source: CIImage(cgImage: decoded), edit: edit, time: 0.8, size: CGSize(width: 1080, height: 1920))
    let context = CIContext()
    let bounds = CGRect(x: 0, y: 0, width: 1080, height: 1920)
    var lhs = [UInt8](repeating: 0, count: 1080 * 1920 * 4), rhs = lhs
    context.render(expected, toBitmap: &lhs, rowBytes: 1080 * 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    context.render(CIImage(cgImage: exported), toBitmap: &rhs, rowBytes: 1080 * 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    var difference = 0.0
    for index in stride(from: 0, to: lhs.count, by: 16) { difference += Double(abs(Int(lhs[index]) - Int(rhs[index]))) }
    #expect(difference / Double(lhs.count / 16) < 12)
    let analysis = try await TimelineAnalysis.load(url: url, document: document)
    let thumbnails = ThumbnailGenerator(url: url, document: document)
    let exact = try await thumbnails.image(at: 0.5, tolerance: 0)
    #expect(exact != nil && (exact?.width ?? 0) > 0)
    await thumbnails.close()
    #expect(analysis.system.max()! > 0.05 && analysis.microphone.max()! > 0.05)
}

@Test func pointerSamplesExcludePauseAndUseExactSegmentOrigins() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "鼠标暂停测试")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: false, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) { writer.ingest(try makeFrame(at: CMTime(seconds: 10, preferredTimescale: 600)), role: .screen) }
    writer.appendPointer(PointerSample(time: 10.5, x: 0.5, y: 0.5, kind: .click))
    await writer.pause(at: CMTime(seconds: 11, preferredTimescale: 600))
    writer.appendPointer(PointerSample(time: 15, x: 0.5, y: 0.5, kind: .click))
    try await Task.sleep(for: .milliseconds(400))
    await writer.resume(at: CMTime(seconds: 20, preferredTimescale: 600))
    writer.appendPointer(PointerSample(time: 20.2, x: 0.5, y: 0.5, kind: .click))
    try await writer.finish(at: CMTime(seconds: 21, preferredTimescale: 600))
    let events = try EditStorage.events(in: url, document: ProjectStorage.load(url))
    #expect(events.count == 2)
    #expect(abs(events[0].time - 0.5) < 0.001)
    #expect(abs(events[1].time - 1.2) < 0.001)
}

/// 使用有方向的彩色梯度验证聚焦位移和坐标翻转，避免单色样本掩盖变换错误。
private func patternFrame(at time: CMTime) throws -> CMSampleBuffer {
    let sample = try makeFrame(at: time)
    let pixel = try #require(sample.imageBuffer)
    CVPixelBufferLockBaseAddress(pixel, [])
    defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
    let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixel)
    for y in 0..<180 {
        for x in 0..<320 {
            let p = y * stride + x * 4
            base[p] = 60; base[p + 1] = UInt8(y * 255 / 180); base[p + 2] = UInt8(x * 255 / 320); base[p + 3] = 255
        }
    }
    return sample
}

@Test(arguments: [CanvasRatio.widescreen, .portrait, .square]) @MainActor func uhdExportUsesRequestedCanvasSize(ratio: CanvasRatio) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "4K 画布")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: false, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) { writer.ingest(try patternFrame(at: CMTime(seconds: 10, preferredTimescale: 600)), role: .screen) }
    try await writer.finish(at: CMTime(seconds: 10.2, preferredTimescale: 600))
    let document = try ProjectStorage.load(url)
    var edit = VideoEdit(duration: document.duration); edit.layout.ratio = ratio
    let target = root.appendingPathComponent("4k.mp4")
    try await ProjectMedia.export(url: url, document: document, levels: edit.audio, destination: target, edit: edit, longEdge: 3840) { _ in }
    let video = try #require(try await AVURLAsset(url: target).loadTracks(withMediaType: .video).first)
    let size = try await video.load(.naturalSize)
    let expected = ratio == .widescreen ? CGSize(width: 3840, height: 2160) : ratio == .portrait ? CGSize(width: 2160, height: 3840) : CGSize(width: 2160, height: 2160)
    #expect(size == expected)
}

@MainActor private final class ExportCancellation {
    var task: Task<Void, any Error>?
    var receivedProgress = false
}

@Test @MainActor func cancellingActiveCompositedExportPreservesDestination() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "合成中取消")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: false, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) { writer.ingest(try patternFrame(at: CMTime(seconds: 10, preferredTimescale: 600)), role: .screen) }
    try await writer.finish(at: CMTime(seconds: 40, preferredTimescale: 600))
    let document = try ProjectStorage.load(url), edit = VideoEdit(duration: 30)
    let target = root.appendingPathComponent("existing.mp4"), original = Data("已有视频内容".utf8)
    try original.write(to: target)
    let cancellation = ExportCancellation()
    cancellation.task = Task {
        try await ProjectMedia.export(url: url, document: document, levels: edit.audio, destination: target, edit: edit, longEdge: 3840) { value in
            if value > 0 && value < 1 { cancellation.receivedProgress = true; cancellation.task?.cancel() }
        }
    }
    do { try await cancellation.task!.value; Issue.record("合成中取消不应提交文件") } catch {}
    cancellation.task = nil
    #expect(cancellation.receivedProgress)
    #expect(try Data(contentsOf: target) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".caplo-export-") })
}

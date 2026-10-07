import AVFoundation
import os
import Testing
import ProjectKit
import ExportKit
import CoreImage
import RenderKit
@testable import CaptureKit

private func cameraTime(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }

/// 固定两种 H.264 描述，确保回归不依赖并发负载恰好触发编码器格式变化。
@Test @MainActor func heterogeneousVideoFormatsUseReusableTracksAndExportInEditedOrder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "混合视频格式")
    let paths = ["Media/high.mov", "Media/baseline.mov"]
    for index in paths.indices {
        let writer = try AVAssetWriter(outputURL: url.appendingPathComponent(paths[index]), fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 120,
            AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: index == 0 ? AVVideoProfileLevelH264HighAutoLevel : AVVideoProfileLevelH264BaselineAutoLevel]
        ])
        writer.add(input); try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        try #require(input.append(try cameraFrame(at: 0, red: index == 0)))
        writer.endSession(atSourceTime: cameraTime(1)); input.markAsFinished()
        await writer.finishWriting(); try #require(writer.status == .completed)
    }
    var document = ProjectDocument(name: "混合视频格式")
    document.segments = (0..<3).map { index in
        SegmentRecord(id: index, duration: 1, files: [.screen: paths[index % 2], .camera: paths[index % 2]])
    }
    var edit = VideoEdit(duration: 3); edit.camera = CameraLayout()
    edit.clips = [VideoClip(sourceStart: 1, duration: 1), VideoClip(sourceStart: 0, duration: 1), VideoClip(sourceStart: 2, duration: 1)]
    let item = try await ProjectMedia.playerItem(url: url, document: document, levels: edit.audio, edit: edit)
    let composition = try #require(item.asset as? AVComposition)
    #expect(composition.tracks.filter { $0.mediaType == .video }.count == 4)
    let instruction = try #require(item.videoComposition?.instructions.first as? SceneInstruction)
    #expect(instruction.screenSource(at: cameraTime(0.5)) != instruction.screenSource(at: cameraTime(1.5)))
    #expect(instruction.cameraSource(at: cameraTime(0.5)) != instruction.cameraSource(at: cameraTime(1.5)))
    #expect(instruction.screenSource(at: cameraTime(1.5)) == instruction.screenSource(at: cameraTime(2.5)))
    #expect(instruction.cameraSource(at: cameraTime(1.5)) == instruction.cameraSource(at: cameraTime(2.5)))
    #expect(instruction.screenSource(at: cameraTime(1)) == instruction.screenSource(at: cameraTime(1.5)))
    let destination = root.appendingPathComponent("mixed.mp4")
    try await ProjectMedia.export(url: url, document: document, levels: edit.audio, destination: destination, edit: edit) { _ in }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    let context = CIContext()
    for time in [0.5, 1.5, 2.5] {
        let image = try await generator.image(at: cameraTime(time)).image
        let rect = try #require(edit.camera).rect(in: CGSize(width: image.width, height: image.height))
        for point in [CGPoint(x: image.width / 2, y: image.height / 2), CGPoint(x: rect.midX, y: rect.midY)] {
            var color = [UInt8](repeating: 0, count: 4)
            context.render(CIImage(cgImage: image), toBitmap: &color, rowBytes: 4, bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            #expect(time < 1 ? color[2] > 200 && color[0] < 20 : color[0] > 200 && color[2] < 20)
        }
    }
}

/// 摄像头中途换了画面尺寸（连续互通相机转向、切换格式）：就地换段，新段按新尺寸建摄像头文件，录制继续。
/// 以前一个编码器只能是一种尺寸，直接结束整段录制。
@Test func cameraSizeChangeStartsANewSegmentInsteadOfStoppingTheRecording() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "摄像头换尺寸")
    let failures = OSAllocatedUnfairLock(initialState: [String]())
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: false, camera: true,
                                        onStarted: {}, onFailure: { message in failures.withLock { $0.append(message) } })
    try await onQueue(writer) {
        writer.ingest(try makeFrame(at: cameraTime(10)), role: .screen)
        for time in [10.0, 10.5] { writer.ingest(try cameraFrame(at: time, red: true), role: .camera) }
        for time in [11.0, 11.5] { writer.ingest(try cameraFrame(at: time, red: false, width: 200), role: .camera) }
    }
    try await writer.finish(at: cameraTime(12))
    #expect(failures.withLock { $0 }.isEmpty, "换尺寸结束了录制：\(failures.withLock { $0 })")
    let document = try ProjectStorage.load(url)
    #expect(document.segments.count == 2 && document.segments.allSatisfy { $0.files[.camera] != nil }, "片段 \(document.segments.map(\.files))")
}

/// 用不同尺寸与纯色辨识两个来源；所有测试只构造像素缓冲，不发现或启动真实设备。
private func cameraFrame(at seconds: Double, red: Bool, width: Int = 160, split: Bool = false) throws -> CMSampleBuffer {
    var created: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, width, 120, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created) == kCVReturnSuccess)
    let pixel = try #require(created)
    CVPixelBufferLockBaseAddress(pixel, [])
    let base = try #require(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
    for y in 0..<120 {
        for x in 0..<width {
            let offset = y * CVPixelBufferGetBytesPerRow(pixel) + x * 4
            let isRed = split ? x < width / 2 : red
            base[offset] = isRed ? 0 : 255; base[offset + 1] = 0
            base[offset + 2] = isRed ? 255 : 0; base[offset + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(pixel, [])
    var description: CMVideoFormatDescription?
    #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &description) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: cameraTime(seconds), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: try #require(description), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
    return try #require(sample)
}


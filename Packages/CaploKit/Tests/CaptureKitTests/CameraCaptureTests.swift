import AVFoundation
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

@Test func cameraChoiceNeverReplacesMissingDeviceOrEnablesDisabledInput() throws {
    let cameras = [CaptureCamera(id: "builtin", name: "内置"), CaptureCamera(id: "usb", name: "USB")]
    #expect(try RecordingCameraPlan.resolve(enabled: true, selectedID: "usb", cameras: cameras, defaultID: "builtin").deviceID == "usb")
    #expect(try RecordingCameraPlan.resolve(enabled: true, selectedID: nil, cameras: cameras, defaultID: "builtin").deviceID == "builtin")
    #expect(throws: RecordingError.self) { try RecordingCameraPlan.resolve(enabled: true, selectedID: "missing", cameras: cameras, defaultID: "builtin") }
    #expect(throws: RecordingError.self) { try RecordingCameraPlan.resolve(enabled: true, selectedID: nil, cameras: cameras, defaultID: nil) }
    #expect(try RecordingCameraPlan.resolve(enabled: false, selectedID: "missing", cameras: [], defaultID: nil).deviceID == nil)
}

/// 实际编码、解码四条素材，检查暂停消失、首帧偏移和重排后的摄像头时间线。
@Test @MainActor func cameraKeepsIndependentDimensionsAndLateFramesAfterPauseAndReorder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "摄像头暂停同步")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: true, microphone: true, camera: true,
        onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) {
        writer.ingest(try makeFrame(at: cameraTime(10)), role: .screen)
        writer.ingest(try cameraFrame(at: 10.25, red: true), role: .camera)
        writer.ingest(try makeAudio(at: cameraTime(10), duration: 1, channels: 2), role: .systemAudio)
        writer.ingest(try makeAudio(at: cameraTime(10), duration: 1, channels: 1), role: .microphone)
    }
    await writer.pause(at: cameraTime(11))
    try await onQueue(writer) {
        // 即使暂停末尾收到新画面，继续时也要等待真正属于新区间的摄像头帧。
        writer.ingest(try cameraFrame(at: 19.99, red: true), role: .camera)
    }
    try await Task.sleep(for: .milliseconds(400))
    await writer.resume(at: cameraTime(20))
    try await onQueue(writer) {
        writer.ingest(try makeFrame(at: cameraTime(20)), role: .screen)
        writer.ingest(try cameraFrame(at: 20.2, red: false), role: .camera)
        writer.ingest(try makeAudio(at: cameraTime(20), duration: 1, channels: 2), role: .systemAudio)
        writer.ingest(try makeAudio(at: cameraTime(20), duration: 1, channels: 1), role: .microphone)
    }
    try await writer.finish(at: cameraTime(21))
    try ProjectStorage.complete(url)
    let document = try ProjectStorage.load(url)
    #expect(document.segments.count == 2)
    #expect(abs(document.duration - 2) < 0.001)
    #expect(document.segments.allSatisfy { $0.files.count == 4 })
    for (index, segment) in document.segments.enumerated() {
        let path = try #require(segment.files[.camera])
        let asset = AVURLAsset(url: try ProjectStorage.mediaURL(path, in: url))
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try await track.load(.naturalSize) == CGSize(width: 160, height: 120))
        let range = try await track.load(.timeRange)
        let offset = segment.offset(for: .camera)
        #expect(abs(offset - (index == 0 ? 0.25 : 0.2)) < 0.001)
        #expect(abs(range.start.seconds) < 0.001)
        #expect(abs(range.end.seconds + offset - 1) < 0.001)
        let decoded = try decodeCamera(asset: asset, track: track)
        #expect(decoded.count == 1)
        let firstFrame = try #require(decoded.first)
        #expect(index == 0 ? firstFrame.red > 200 : firstFrame.blue > 200)
    }
    var edit = VideoEdit(duration: document.duration)
    edit.clips = [VideoClip(sourceStart: 1, duration: 1), VideoClip(sourceStart: 0, duration: 1)]
    let (composition, mix) = try await ProjectMedia.compose(url: url, document: document, levels: edit.audio, edit: edit)
    #expect(mix.inputParameters.count == 2)
    let cameras = composition.tracks.filter { $0.mediaType == .video && $0.trackID >= 4 && $0.trackID % 2 == 0 }
    let ranges = cameras.flatMap { $0.segments.filter { !$0.isEmpty }.map { $0.timeMapping.target } }.sorted { $0.start < $1.start }
    #expect(ranges.count == 2)
    #expect(abs(ranges[0].start.seconds - 0.2) < 0.001)
    #expect(abs(ranges[1].start.seconds - 1.25) < 0.001)
    var cameraEdit = edit; cameraEdit.camera = CameraLayout()
    let destination = root.appendingPathComponent("reordered-camera.mp4")
    try await ProjectMedia.export(url: url, document: document, levels: edit.audio, destination: destination, edit: cameraEdit) { _ in }
    let finalGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
    finalGenerator.requestedTimeToleranceBefore = .zero; finalGenerator.requestedTimeToleranceAfter = .zero
    for time in [0.6, 1.6] {
        let image = try await finalGenerator.image(at: cameraTime(time)).image
        let rect = try #require(cameraEdit.camera).rect(in: CGSize(width: image.width, height: image.height))
        var color = [UInt8](repeating: 0, count: 4)
        CIContext().render(CIImage(cgImage: image), toBitmap: &color, rowBytes: 4, bounds: CGRect(x: rect.midX, y: rect.midY, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        #expect(time < 1 ? color[2] > 200 && color[0] < 20 : color[0] > 200 && color[2] < 20)
    }
    // 合成轨道可能解码出空区间的黑帧；分别检查有效范围内的实际颜色。
    let samples = try cameras.flatMap { try decodeCamera(asset: composition, track: $0) }
    let blue = try #require(samples.first { abs($0.time - 0.2) < 0.001 })
    let red = try #require(samples.first { abs($0.time - 1.25) < 0.001 })
    #expect(blue.blue > 200 && blue.red < 20)
    #expect(red.red > 200 && red.blue < 20)
    // 拆分以后裁掉首帧前的空白时，摄像头轨道应从零开始而非保留旧偏移。
    edit.clips = [VideoClip(sourceStart: 0.5, duration: 0.5)]
    let (trimmed, _) = try await ProjectMedia.compose(url: url, document: document, levels: edit.audio, edit: edit)
    let trimmedCamera = try #require(trimmed.track(withTrackID: 4))
    #expect(abs(trimmedCamera.timeRange.start.seconds) < 0.001)
    #expect(abs(trimmedCamera.timeRange.duration.seconds - 0.5) < 0.001)
}

@Test @MainActor func cameraRotationSeedsOnlyBoundaryFrameAndIgnoresLateOlderFrameInNextSegment() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "摄像头片段边界")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: false, camera: true,
        segmentSeconds: 0.5, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) {
        writer.ingest(try makeFrame(at: cameraTime(10)), role: .screen)
        writer.ingest(try cameraFrame(at: 10.45, red: true), role: .camera)
        writer.ingest(try makeFrame(at: cameraTime(10.5)), role: .screen)
        writer.ingest(try cameraFrame(at: 10.48, red: false), role: .camera)
        writer.ingest(try cameraFrame(at: 10.6, red: false), role: .camera)
    }
    try await writer.finish(at: cameraTime(11))
    let document = try ProjectStorage.load(url)
    #expect(document.segments.count == 2)
    let path = try #require(document.segments.last?.files[.camera])
    let asset = AVURLAsset(url: try ProjectStorage.mediaURL(path, in: url))
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let frames = try decodeCamera(asset: asset, track: track)
    #expect(frames.count == 2)
    #expect(abs(frames[0].time) < 0.001 && frames[0].red > 200)
    #expect(abs(frames[1].time - 0.1) < 0.001 && frames[1].blue > 200)
}

@Test func cameraFormatChangeFailsAndPreservesAlreadyWrittenMedia() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "摄像头格式变化")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: false, camera: true,
        onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) {
        writer.ingest(try makeFrame(at: cameraTime(10)), role: .screen)
        writer.ingest(try cameraFrame(at: 10, red: true), role: .camera)
        writer.ingest(try cameraFrame(at: 10.2, red: false, width: 240), role: .camera)
    }
    await #expect(throws: RecordingError.self) { try await writer.finish(at: cameraTime(10.3)) }
    let document = try ProjectStorage.load(url)
    #expect(document.segments.count == 1)
    #expect(document.segments.first?.files[.camera] != nil)
}

@Test @MainActor func cameraCrossingBoundaryBeforeScreenCallbackDoesNotLoseFrame() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "摄像头先于屏幕跨段")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: false, camera: true,
        segmentSeconds: 0.5, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) {
        writer.ingest(try makeFrame(at: cameraTime(10)), role: .screen)
        writer.ingest(try cameraFrame(at: 10.45, red: true), role: .camera)
        // 摄像头比屏幕回调早到；蓝帧必须进入新段，不能被旧段结束时间裁掉。
        writer.ingest(try cameraFrame(at: 10.6, red: false), role: .camera)
        writer.ingest(try makeFrame(at: cameraTime(10.5)), role: .screen)
    }
    try await writer.finish(at: cameraTime(11))
    let document = try ProjectStorage.load(url)
    #expect(document.segments.count == 2)
    let segment = try #require(document.segments.last)
    #expect(segment.offset(for: .camera) == 0)
    let path = try #require(segment.files[.camera])
    let asset = AVURLAsset(url: try ProjectStorage.mediaURL(path, in: url))
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let frames = try decodeCamera(asset: asset, track: track)
    #expect(frames.count == 2)
    #expect(frames[0].red > 200 && abs(frames[0].time) < 0.001)
    #expect(frames[1].blue > 200 && abs(frames[1].time - 0.1) < 0.001)
}

@Test func stopBoundaryRejectsFramesArrivingWhileDevicesShutDown() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "停止边界冻结")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: false, camera: true,
        segmentSeconds: 0.5, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) {
        writer.ingest(try makeFrame(at: cameraTime(10)), role: .screen)
        writer.ingest(try cameraFrame(at: 10, red: true), role: .camera)
    }
    await writer.pause(at: cameraTime(10.4))
    try await onQueue(writer) {
        writer.ingest(try makeFrame(at: cameraTime(12)), role: .screen)
        writer.ingest(try cameraFrame(at: 12, red: false), role: .camera)
    }
    try await writer.finish(at: cameraTime(10.4))
    let document = try ProjectStorage.load(url)
    #expect(document.segments.count == 1)
    #expect(abs(document.duration - 0.4) < 0.001)
    var invalid = document
    invalid.segments[0].mediaOffsets = [.camera: 0.4]
    try ProjectStorage.save(invalid, to: url)
    #expect(throws: ProjectError.self) { try ProjectStorage.load(url) }
}

@Test func disabledCameraCannotCreateVideoOrAlterLegacyProject() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "关闭摄像头")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: false,
        onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) {
        writer.ingest(try makeFrame(at: cameraTime(10)), role: .screen)
        writer.ingest(try cameraFrame(at: 10, red: true), role: .camera)
    }
    try await writer.finish(at: cameraTime(11))
    let document = try ProjectStorage.load(url)
    #expect(document.segments.first?.files.count == 1)
    let legacy = Data(#"{"desktopBounds":[[0,0],[320,180]],"pixelSize":[320,180],"pointPixelScale":1,"pointerEnabled":true}"#.utf8)
    let metadata = try JSONDecoder().decode(CaptureMetadata.self, from: legacy)
    #expect(metadata.cameraDeviceID == nil)
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

/// 首帧前、缺失段和有效段都走实际导出；检查镜像及播放指令，避免仅静帧正确。
@Test(arguments: CameraLayout.Shape.allCases) @MainActor func pictureInPicturePreviewAndExportRespectGapsMirrorAndEditing(shape: CameraLayout.Shape) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "画中画一致性")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: true, camera: true,
        onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) {
        writer.ingest(try makeFrame(at: cameraTime(10)), role: .screen)
        writer.ingest(try cameraFrame(at: 10.25, red: true, split: true), role: .camera)
        writer.ingest(try makeAudio(at: cameraTime(10), duration: 1, channels: 1), role: .microphone)
    }
    await writer.pause(at: cameraTime(11))
    try await Task.sleep(for: .milliseconds(400))
    await writer.resume(at: cameraTime(20))
    try await onQueue(writer) { writer.ingest(try makeFrame(at: cameraTime(20)), role: .screen) }
    try await writer.finish(at: cameraTime(21))
    let document = try ProjectStorage.load(url)
    var edit = try EditStorage.load(in: url, document: document)
    #expect(edit.camera?.enabled == true)
    edit.clips = [VideoClip(sourceStart: 1, duration: 1), VideoClip(sourceStart: 0, duration: 1)]
    edit.camera?.shape = shape; edit.camera?.size = 0.4
    edit.camera?.x = 0.5; edit.camera?.y = 0.5; edit.camera?.shadow = false
    let item = try await ProjectMedia.playerItem(url: url, document: document, levels: edit.audio, edit: edit)
    let instruction = try #require(item.videoComposition?.instructions.first as? SceneInstruction)
    #expect(!instruction.cameraVisible(at: cameraTime(0.5)))
    #expect(!instruction.cameraVisible(at: cameraTime(1.1)))
    #expect(instruction.cameraVisible(at: cameraTime(1.6)))
    let renderer = EditorPreviewRenderer()
    let size = CGSize(width: 1280, height: 720)
    let rect = try #require(edit.camera).rect(in: size)
    let point = CGPoint(x: rect.minX + rect.width * 0.25, y: rect.midY)
    let context = CIContext()
    func pixel(_ image: CGImage, at point: CGPoint, size: CGSize) -> [UInt8] {
        let normalized = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: size.width / Double(image.width), y: size.height / Double(image.height)))
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(normalized, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes
    }
    for time in [0.5, 1.1] {
        let image = try await renderer.render(url: url, document: document, edit: edit, time: time)
        let color = pixel(image, at: point, size: size)
        #expect(abs(Int(color[0]) - Int(color[2])) < 10 && color[0] > 80)
    }
    let mirrored = try await renderer.render(url: url, document: document, edit: edit, time: 1.6)
    let outsideShape = CGPoint(x: rect.minX + rect.width * 0.01, y: rect.minY + rect.height * 0.01)
    let corner = pixel(mirrored, at: outsideShape, size: size)
    #expect(abs(Int(corner[0]) - Int(corner[2])) < 10 && corner[0] > 80)
    #expect(pixel(mirrored, at: point, size: size)[2] > 220)
    var unmirrored = edit; unmirrored.camera?.mirrored = false
    let normal = try await renderer.render(url: url, document: document, edit: unmirrored, time: 1.6)
    #expect(pixel(normal, at: point, size: size)[0] > 220)
    let decodedCount = await renderer.decodedFrameCount
    var focused = edit
    focused.focuses = [FocusSegment(start: 0, duration: 1, x: 0.5, y: 0.5, scale: 2)]
    let zoomed = try await renderer.render(url: url, document: document, edit: focused, time: 1.6)
    #expect(pixel(zoomed, at: point, size: size)[2] > 220)
    #expect(await renderer.decodedFrameCount == decodedCount)
    try ProjectMedia.updatePresentation(item: item, previous: edit, edit: unmirrored)
    #expect((item.videoComposition?.instructions.first as? SceneInstruction)?.edit.camera?.mirrored == false)
    let target = root.appendingPathComponent("pip.mp4")
    try await ProjectMedia.export(url: url, document: document, levels: edit.audio, destination: target, edit: edit) { _ in }
    let asset = AVURLAsset(url: target)
    #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    for time in [0.5, 1.1, 1.6] {
        let exported = try await generator.image(at: cameraTime(time)).image
        let preview = try await renderer.render(url: url, document: document, edit: edit, time: time)
        let actual = pixel(exported, at: point, size: size), expected = pixel(preview, at: point, size: size)
        #expect(zip(actual.prefix(3), expected.prefix(3)).allSatisfy { abs(Int($0) - Int($1)) < 16 }, "时间 \(time)：导出 \(actual)，预览 \(expected)")
    }
    var hidden = edit; hidden.camera?.enabled = false
    let hiddenImage = try await renderer.render(url: url, document: document, edit: hidden, time: 1.6)
    #expect(abs(Int(pixel(hiddenImage, at: point, size: size)[0]) - Int(pixel(hiddenImage, at: point, size: size)[2])) < 10)
    await renderer.close()
}

@MainActor private func decodeCamera(asset: AVAsset, track: AVAssetTrack) throws -> [(time: Double, red: UInt8, blue: UInt8)] {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    #expect(reader.startReading())
    var frames: [(Double, UInt8, UInt8)] = []
    while let sample = output.copyNextSampleBuffer() {
        let pixel = try #require(sample.imageBuffer)
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        let base = try #require(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
        frames.append((sample.presentationTimeStamp.seconds, base[2], base[0]))
        CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
    }
    #expect(reader.status == .completed, "解码错误：\(String(describing: reader.error))")
    return frames
}

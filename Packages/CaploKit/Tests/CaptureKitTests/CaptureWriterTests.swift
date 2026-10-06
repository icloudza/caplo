import AVFoundation
import CoreVideo
import Testing
import ProjectKit
@testable import CaptureKit

/// 使用合成帧验证编码器，不触发屏幕权限，不采集用户桌面。
@Test func writesPlayableMovieAndPreservesStaticTail() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "静态画面测试")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: false, onStarted: {}, onFailure: { _ in })
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        writer.queue.async {
            do {
                let sample = try makeFrame(at: CMTime(seconds: 10, preferredTimescale: 600))
                writer.ingest(sample, role: .screen)
                continuation.resume()
            } catch { continuation.resume(throwing: error) }
        }
    }
    try await writer.finish(at: CMTime(seconds: 13, preferredTimescale: 600))
    let document = try ProjectStorage.load(url)
    let path = try #require(document.segments.first?.files[.screen])
    let asset = AVURLAsset(url: try ProjectStorage.mediaURL(path, in: url))
    let duration = try await asset.load(.duration)
    #expect(abs(duration.seconds - 3) < 0.1)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    #expect(tracks.count == 1)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: try #require(tracks.first), outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    #expect(reader.startReading())
    #expect(output.copyNextSampleBuffer() != nil)
    reader.cancelReading()
}

@Test func recordingWithoutFramesFailsInsteadOfReportingSuccess() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "无帧测试")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: false, onStarted: {}, onFailure: { _ in })
    await #expect(throws: RecordingError.self) {
        try await writer.finish(at: CMTime(seconds: 1, preferredTimescale: 600))
    }
}

func makeFrame(at time: CMTime) throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess,
          let pixel else { throw RecordingError.message("测试像素缓冲创建失败") }
    CVPixelBufferLockBaseAddress(pixel, [])
    if let base = CVPixelBufferGetBaseAddress(pixel) {
        memset(base, 128, CVPixelBufferGetBytesPerRow(pixel) * CVPixelBufferGetHeight(pixel))
    }
    CVPixelBufferUnlockBaseAddress(pixel, [])
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format) == noErr,
          let format else { throw RecordingError.message("测试视频描述创建失败") }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format,
                                                sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
          let sample else { throw RecordingError.message("测试视频帧创建失败") }
    return sample
}

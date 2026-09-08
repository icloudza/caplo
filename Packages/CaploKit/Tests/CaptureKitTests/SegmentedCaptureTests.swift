import Foundation
import AVFoundation
import Testing
import ProjectKit
import ExportKit
@testable import CaptureKit

private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }

@Test func reverseRegionDragClampsToDisplayBounds() {
    let rect = CaptureRegion.clampedDrag(from: CGPoint(x: 800, y: 700), to: CGPoint(x: -10, y: 100), in: CGRect(x: 0, y: 0, width: 960, height: 540))
    #expect(rect == CGRect(x: 0, y: 100, width: 800, height: 440))
    #expect(CaptureRegion.clampedDrag(from: CGPoint(x: -100, y: -100), to: CGPoint(x: -10, y: -10), in: CGRect(x: 0, y: 0, width: 960, height: 540)) == .zero)
}

/// 合成帧与音频通过生产采集入口写入；十秒暂停必须从工程及最终 MP4 中消失。
@Test @MainActor func pauseProducesContinuousProjectWithTwoAudioTracksAndExport() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "音画暂停测试")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: true, microphone: true,
        onStarted: {}, onFailure: { _ in })
    try await samples(writer, start: 10)
    await writer.pause(at: time(11))
    // 模拟暂停期间仍有采集回调，不能将这些数据写进下一段。
    try await samples(writer, start: 15)
    try await Task.sleep(for: .milliseconds(450))
    await writer.resume(at: time(20))
    try await samples(writer, start: 20)
    try await writer.finish(at: time(21))
    try ProjectStorage.complete(url)
    let document = try ProjectStorage.load(url)
    #expect(document.segments.count == 2)
    #expect(abs(document.duration - 2) < 0.01)
    #expect(document.segments.allSatisfy { $0.files.count == 3 })
    let (mutableComposition, _) = try await ProjectMedia.compose(url: url, document: document, levels: AudioLevels())
    let composition = mutableComposition.copy() as! AVComposition
    #expect(composition.tracks.filter { $0.mediaType == .audio }.count == 2)
    #expect(abs(composition.duration.seconds - 2) < 0.05)
    let export = root.appendingPathComponent("result.mp4")
    try await ProjectMedia.export(url: url, document: document, levels: AudioLevels(), destination: export) { _ in }
    let asset = AVURLAsset(url: export)
    #expect(abs(try await asset.load(.duration).seconds - 2) < 0.08)
    #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    // 仅在显式指定目录时保留合成工程，供离屏布局检查使用，不混入用户项目库。
    if let output = ProcessInfo.processInfo.environment["CAPLO_TEST_FIXTURE_DIRECTORY"] {
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent("demo.caplo"))
    }
}

@Test @MainActor func crossingAudioPacketIsPreservedAcrossRotation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "片段边界测试")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: true, microphone: false,
        segmentSeconds: 0.5, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) {
        writer.ingest(try makeFrame(at: time(10)), role: .screen)
        writer.ingest(try makeAudio(at: time(10), duration: 0.25, channels: 2), role: .systemAudio)
        writer.ingest(try makeFrame(at: time(10.5)), role: .screen)
        writer.ingest(try makeAudio(at: time(10.25), duration: 0.5, channels: 2), role: .systemAudio)
        writer.ingest(try makeAudio(at: time(10.75), duration: 0.25, channels: 2), role: .systemAudio)
    }
    try await writer.finish(at: time(11))
    let document = try ProjectStorage.load(url)
    #expect(document.segments.count == 2)
    let (mutableComposition, _) = try await ProjectMedia.compose(url: url, document: document, levels: AudioLevels())
    let composition = mutableComposition.copy() as! AVComposition
    let audio = try #require(composition.tracks.first { $0.mediaType == .audio })
    let range = audio.timeRange
    #expect(abs(range.duration.seconds - 1) < 0.01)
    // 检查实际解码样本数，避免仅有容器时长正确、音频边界却存在缺口。
    let reader = try AVAssetReader(asset: composition)
    let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
    reader.add(output)
    #expect(reader.startReading())
    var frames = 0
    while let sample = output.copyNextSampleBuffer() { frames += sample.numSamples }
    #expect(abs(frames - 48_000) < 48)
}

@Test @MainActor func cancelledExportDoesNotReplaceExistingFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "导出取消测试")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: false,
        onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) { writer.ingest(try makeFrame(at: time(10)), role: .screen) }
    try await writer.finish(at: time(11))
    let document = try ProjectStorage.load(url)
    let target = root.appendingPathComponent("existing.mp4")
    let original = Data("原有文件".utf8)
    try original.write(to: target)
    let task = Task { try await ProjectMedia.export(url: url, document: document, levels: AudioLevels(), destination: target) { _ in } }
    task.cancel()
    do { try await task.value; Issue.record("取消的导出不应成功") } catch {}
    #expect(try Data(contentsOf: target) == original)
}

private func samples(_ writer: SegmentedCaptureWriter, start: Double) async throws {
    try await onQueue(writer) {
        writer.ingest(try makeFrame(at: time(start)), role: .screen)
        writer.ingest(try makeAudio(at: time(start), duration: 1, channels: 2), role: .systemAudio)
        writer.ingest(try makeAudio(at: time(start), duration: 1, channels: 1), role: .microphone)
    }
}

@Test func acceptsNonInterleavedAudioFromCaptureFormat() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "非交错音频测试")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: true, microphone: false,
        onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) {
        writer.ingest(try makeFrame(at: time(10)), role: .screen)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        pcm.frameLength = 480
        for channel in 0..<2 {
            for frame in 0..<480 { pcm.floatChannelData![channel][frame] = 0.1 }
        }
        var description: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: time(1.0 / 48_000), presentationTimeStamp: time(10), decodeTimeStamp: .invalid)
        #expect(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: 480,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
        let buffer = try #require(sample)
        #expect(CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr)
        #expect(CMSampleBufferSetDataReady(buffer) == noErr)
        writer.ingest(buffer, role: .systemAudio)
    }
    try await writer.finish(at: time(10.1))
    let document = try ProjectStorage.load(url)
    #expect(document.segments.first?.files[.systemAudio] != nil)
}

func onQueue(_ writer: SegmentedCaptureWriter, action: @escaping @Sendable () throws -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        writer.queue.async {
            do { try action(); continuation.resume() } catch { continuation.resume(throwing: error) }
        }
    }
}

func makeAudio(at time: CMTime, duration: Double, channels: UInt32, sampleRate: Double = 48_000) throws -> CMSampleBuffer {
    let count = Int(duration * sampleRate)
    var description = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: channels * 4,
        mFramesPerPacket: 1, mBytesPerFrame: channels * 4, mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    guard formatStatus == noErr, let format else { throw RecordingError.message("测试音频格式创建失败") }
    var block: CMBlockBuffer?
    let length = count * Int(channels) * 4
    guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == noErr,
        let block else { throw RecordingError.message("测试音频缓冲创建失败") }
    // 非零音频可进一步验证混音增益，而不仅仅验证是否存在音轨。
    let values = [Float](repeating: 0.1, count: count * Int(channels))
    _ = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)), presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var size = Int(channels) * 4
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
        sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else {
        throw RecordingError.message("测试音频样本创建失败")
    }
    return sample
}

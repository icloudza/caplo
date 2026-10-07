import AVFoundation
import Testing
import ProjectKit
import ExportKit
import EditingCore
@testable import CaptureKit

/// 检查实际导出的 AAC 波形，避免只验证 AVAudioMix 参数却遗漏导出未使用混音的情况。
@Test @MainActor func exportedAudioHonorsSoloAndMuteWithoutChangingStoredVolume() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "静音与独奏导出")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: true, microphone: true, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) {
        let start = CMTime(seconds: 10, preferredTimescale: 600)
        writer.ingest(try makeFrame(at: start), role: .screen)
        writer.ingest(try makeAudio(at: start, duration: 1, channels: 2), role: .systemAudio)
        writer.ingest(try makeAudio(at: start, duration: 1, channels: 1), role: .microphone)
    }
    try await writer.finish(at: CMTime(seconds: 11, preferredTimescale: 600))
    try ProjectStorage.complete(url)
    let document = try ProjectStorage.load(url)
    var edit = VideoEdit(duration: 1)
    edit.audio.system = 0.6; edit.audio.microphone = 0.3
    func exportRMS(_ edit: VideoEdit, name: String) async throws -> Double {
        let destination = root.appendingPathComponent(name + ".mp4")
        try await ProjectMedia.export(url: url, document: document, levels: edit.audio, destination: destination, edit: edit) { _ in }
        let asset = AVURLAsset(url: destination)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); #expect(reader.startReading())
        var energy = 0.0, count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = sample.dataBuffer else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / 4)
            let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            #expect(status == kCMBlockBufferNoErr)
            for value in values { energy += Double(value * value) }; count += values.count
        }
        #expect(reader.status == .completed)
        #expect(count > 10_000)
        return sqrt(energy / Double(max(1, count)))
    }
    let combined = try await exportRMS(edit, name: "combined")
    edit.audio.solo = [.microphone]
    let isolated = try await exportRMS(edit, name: "solo")
    #expect(combined > 0.02 && isolated > 0.005)
    #expect(abs(isolated / combined - 1.0 / 3) < 0.06)
    edit.audio.muted = [.microphone]
    let silence = try await exportRMS(edit, name: "muted-solo")
    #expect(silence < 0.0001)

    // 独立编辑的麦克风切成四块（互不重叠）：共用一条轨，不再一块一轨；每块自己的增益照样作用到混音上。
    var layered = edit; layered.audio.solo = [.microphone]; layered.audio.muted = []
    layered.prepareLayerEditing(camera: false, system: true, microphone: true)
    for time in [0.25, 0.5, 0.75] {
        let id = try #require(layered.mediaClips(.microphone).first { ($0.timelineStart ?? 0) < time && ($0.timelineStart ?? 0) + $0.duration > time }?.id)
        #expect(layered.splitMedia(.microphone, id: id, at: time) != nil)
    }
    #expect(layered.mediaClips(.microphone).count == 4)
    let (layeredComposition, _) = try await ProjectMedia.compose(url: url, document: document, levels: layered.audio, edit: layered)
    #expect(layeredComposition.tracks(withMediaType: .audio).count == 2, "四块麦克风建了 \(layeredComposition.tracks(withMediaType: .audio).count - 1) 条轨")
    layered.setMediaClips(.microphone, layered.mediaClips(.microphone).map { var clip = $0; clip.microphoneGain = 0; return clip })
    #expect(try await exportRMS(layered, name: "layered-silent") < 0.0001, "共用一条轨后单块增益没生效")

    try EditStorage.save(edit, in: url, document: document)
    let reopened = try EditStorage.load(in: url, document: document)
    #expect(reopened.audio == edit.audio)
    #expect(reopened.audio.microphone == 0.3)
}

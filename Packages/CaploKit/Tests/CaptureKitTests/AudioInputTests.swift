import AVFoundation
import Testing
import ProjectKit
@testable import CaptureKit

@Test func microphoneSelectionResolvesExactDeviceAndNeverFallsBack() throws {
    let devices = [CaptureMicrophone(id: "builtin", name: "内置"), CaptureMicrophone(id: "usb", name: "USB")]
    var options = RecordingOptions()
    options.microphone = true; options.microphoneDeviceID = "usb"
    let selected = try RecordingAudioPlan.resolve(options: options, microphones: devices, defaultMicrophoneID: "builtin", applicationIDs: [])
    #expect(selected.microphoneDeviceID == "usb")
    options.microphoneDeviceID = nil
    #expect(try RecordingAudioPlan.resolve(options: options, microphones: devices, defaultMicrophoneID: "builtin", applicationIDs: []).microphoneDeviceID == "builtin")
    options.microphoneDeviceID = "disconnected"
    #expect(throws: RecordingError.self) { try RecordingAudioPlan.resolve(options: options, microphones: devices, defaultMicrophoneID: "builtin", applicationIDs: []) }
    options.microphone = false
    #expect(try RecordingAudioPlan.resolve(options: options, microphones: [], defaultMicrophoneID: nil, applicationIDs: []).microphoneDeviceID == nil)
}

@Test func applicationAudioRejectsEmptyOrUnavailableSelection() throws {
    var options = RecordingOptions()
    options.systemAudio = true
    let all = try RecordingAudioPlan.resolve(options: options, microphones: [], defaultMicrophoneID: nil, applicationIDs: [])
    #expect(all.systemAudio && all.applicationBundleIDs == nil)
    options.systemAudioApplicationBundleIDs = []
    #expect(throws: RecordingError.self) { try RecordingAudioPlan.resolve(options: options, microphones: [], defaultMicrophoneID: nil, applicationIDs: ["com.demo.player"]) }
    options.systemAudioApplicationBundleIDs = ["com.demo.player", "com.demo.player"]
    let selected = try RecordingAudioPlan.resolve(options: options, microphones: [], defaultMicrophoneID: nil, applicationIDs: ["com.demo.player.helper", "com.unrelated.player"])
    #expect(selected.applicationBundleIDs == ["com.demo.player"])
    #expect(!RecordingAudioPlan.matches(application: "com.demo.playerOther", selection: "com.demo.player"))
    #expect(throws: RecordingError.self) { try RecordingAudioPlan.resolve(options: options, microphones: [], defaultMicrophoneID: nil, applicationIDs: ["com.demo.playerOther"]) }
    options.systemAudio = false
    #expect(try RecordingAudioPlan.resolve(options: options, microphones: [], defaultMicrophoneID: nil, applicationIDs: []).systemAudio == false)
}

/// 用两个不同时间原点的真实 Core Media 时间基准验证对齐，保持像素引用和单帧时长。
@Test func independentStreamTimestampsConvertToHostClock() throws {
    let host = CMClockGetHostTimeClock()
    let anchor = CMClockGetTime(host)
    var created: CMTimebase?
    #expect(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: host, timebaseOut: &created) == noErr)
    let source = try #require(created)
    #expect(CMTimebaseSetRate(source, rate: 1) == noErr)
    #expect(CMTimebaseSetAnchorTime(source, timebaseTime: CMTime(seconds: 100, preferredTimescale: 60_000), immediateSourceTime: anchor) == noErr)
    let sample = try makeFrame(at: CMTime(seconds: 100.5, preferredTimescale: 60_000))
    let aligned = try MediaClockBridge.retime(sample, from: source, to: host)
    #expect(abs((aligned.presentationTimeStamp - anchor).seconds - 0.5) < 0.0001)
    #expect(abs(aligned.duration.seconds - sample.duration.seconds) < 0.0001)
    #expect(CMSampleBufferGetImageBuffer(aligned) === CMSampleBufferGetImageBuffer(sample))
    let unchanged = try MediaClockBridge.retime(aligned, from: host, to: host)
    #expect(unchanged === aligned)
}

/// 外接设备常用 44.1 kHz 立体声，原始轨道必须实际转换成工程使用的 48 kHz 单声道。
@Test func externalMicrophoneFormatConvertsWithoutLosingDuration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "外接麦克风格式")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: true, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) {
        writer.ingest(try makeFrame(at: CMTime(seconds: 10, preferredTimescale: 48_000)), role: .screen)
        writer.ingest(try makeAudio(at: CMTime(seconds: 10, preferredTimescale: 44_100), duration: 0.2, channels: 2, sampleRate: 44_100), role: .microphone)
    }
    try await writer.finish(at: CMTime(seconds: 10.2, preferredTimescale: 48_000))
    let document = try ProjectStorage.load(url)
    let path = try #require(document.segments.first?.files[.microphone])
    let asset = AVURLAsset(url: try ProjectStorage.mediaURL(path, in: url))
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let format = try #require(try await track.load(.formatDescriptions).first)
    let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format))
    #expect(asbd.pointee.mSampleRate == 48_000)
    #expect(asbd.pointee.mChannelsPerFrame == 1)
    #expect(abs(try await track.load(.timeRange).duration.seconds - 0.2) < 0.02)
}

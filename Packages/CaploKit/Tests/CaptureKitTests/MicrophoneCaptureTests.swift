import AVFoundation
import CoreAudio
import CoreMedia
import Testing
import ProjectKit
@testable import CaptureKit

/// 采样块转样本：时间戳按给定值、帧数与格式保持；需要转换时（24 kHz 立体声 → 48 kHz 单声道）帧数按比例变化、时间戳不变。
@Test func pcmBuffersBecomeSamplesWithGivenTimestamp() throws {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)); buffer.frameLength = 1024
    for index in 0..<1024 { buffer.floatChannelData![0][index] = Float(sin(Double(index) / 10)) }
    let time = CMTime(value: 123_456, timescale: 48_000)
    let sample = try #require(MicrophoneCapture.sampleBuffer(from: buffer, presentationTime: time, converter: nil))
    #expect(CMSampleBufferGetNumSamples(sample) == 1024 && sample.presentationTimeStamp == time)
    let description = try #require(sample.formatDescription?.audioStreamBasicDescription)
    #expect(description.mSampleRate == 48_000 && description.mChannelsPerFrame == 1)
    // 样本再转回采样块：数据一致。
    let round = try #require(MicrophoneCapture.pcmBuffer(from: sample, format: format))
    #expect(round.frameLength == 1024 && abs(round.floatChannelData![0][500] - buffer.floatChannelData![0][500]) < 1e-6)

    let stereo = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 2, interleaved: false))
    let low = try #require(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 480)); low.frameLength = 480
    let converter = try #require(AVAudioConverter(from: stereo, to: MicrophoneCapture.targetFormat))
    let converted = try #require(MicrophoneCapture.sampleBuffer(from: low, presentationTime: time, converter: converter))
    let frames = CMSampleBufferGetNumSamples(converted)
    #expect(frames > 800 && frames <= 1024 && converted.presentationTimeStamp == time, "\(frames)")
    let output = try #require(converted.formatDescription?.audioStreamBasicDescription)
    #expect(output.mSampleRate == 48_000 && output.mChannelsPerFrame == 1)
}

/// 电平按样本实际格式读：满幅正弦（浮点、16 位整数）接近 1，静音为 0，NaN 归零；-55…-10 dB 映射到 0…1。
@Test func sampleBufferLevelFollowsTheActualFormat() throws {
    func level(_ format: AVAudioFormat, fill: (AVAudioPCMBuffer) -> Void) throws -> Float {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)); buffer.frameLength = 4800
        fill(buffer)
        let sample = try #require(MicrophoneCapture.sampleBuffer(from: buffer, presentationTime: .zero, converter: nil))
        return MicrophoneCapture.level(of: sample)
    }
    let float = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true))
    let loud = try level(float) { for index in 0..<4800 { $0.floatChannelData![0][index] = Float(sin(Double(index) / 4)) } }
    #expect(loud == 1)
    let speech = try level(float) { for index in 0..<4800 { $0.floatChannelData![0][index] = Float(sin(Double(index) / 4)) * 0.05 } }   // 约 -29 dB
    #expect(speech > 0.5 && speech < 0.65, "\(speech)")
    #expect(try level(float) { _ in } == 0)
    let int16 = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))
    #expect(try level(int16) { for index in 0..<4800 { $0.int16ChannelData![0][index] = Int16(sin(Double(index) / 4) * 32_000) } } > 0.99)
    #expect(MicrophoneCapture.decibelLevel(rms: .nan) == 0 && MicrophoneCapture.decibelLevel(rms: 0) == 0)
    #expect(abs(MicrophoneCapture.decibels(level: 0.5) - (-32.5)) < 0.01)
}

/// 设备 UID 换算设备号：默认输出设备能换回自己，胡编的 UID 得到未知。
@Test func deviceUIDsTranslateToDeviceIDs() throws {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var device = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != kAudioObjectUnknown {
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr, let uid {
            #expect(MicrophoneCapture.audioDeviceID(forUID: uid.takeRetainedValue() as String) == device)
        }
    }
    #expect(MicrophoneCapture.audioDeviceID(forUID: "caplo-no-such-device") == kAudioObjectUnknown)
}

@MainActor @Test func microphoneModeNamesMatchTheSystemPanel() {
    #expect(MicrophoneModes.name(.standard) == "标准" && MicrophoneModes.name(.voiceIsolation) == "语音突显" && MicrophoneModes.name(.wideSpectrum) == "宽谱")
    MicrophoneModes.shared.refresh()
    #expect(!MicrophoneModes.shared.currentName.isEmpty)
}

/// 麦克风列表要过滤掉聚合设备：临时建一个私有聚合设备，它不能被当成麦克风；找不到的 UID 保留。
@Test func aggregateDevicesAreNotSelectableMicrophones() throws {
    let uid = "com.caplo.tests.aggregate." + UUID().uuidString
    let description: [String: Any] = [kAudioAggregateDeviceUIDKey: uid, kAudioAggregateDeviceNameKey: "Caplo 测试聚合", kAudioAggregateDeviceIsPrivateKey: 1]
    var device = kAudioObjectUnknown
    guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &device) == noErr, device != kAudioObjectUnknown else { return }
    defer { AudioHardwareDestroyAggregateDevice(device) }
    // 新建的设备要过一会儿才会出现在系统的设备列表里；等它登记好再断言，否则这条测试会偶发红。
    var found = MicrophoneCapture.audioDeviceID(forUID: uid)
    for _ in 0..<40 where found != device {
        usleep(25_000)
        found = MicrophoneCapture.audioDeviceID(forUID: uid)
    }
    #expect(found == device)
    #expect(!MicrophoneCapture.isSelectableMicrophone(uid: uid))
    #expect(MicrophoneCapture.isSelectableMicrophone(uid: "caplo-no-such-device"))
}

/// 录制器借用试听中的采集：写入器随时挂上 / 摘下，引擎不动；没在试听时借不到（摄像头会话同理），录制器自己起一路。
@MainActor @Test func recorderBorrowsTheMonitoredCaptureWithoutRestarting() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "借用麦克风")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: true, onStarted: {}, onFailure: { _ in })
    let capture = MicrophoneCapture(writer: nil, onFailure: { _ in })
    #expect(!capture.isAttached)
    capture.attach(writer: writer, onFailure: { _ in })
    #expect(capture.isAttached)
    capture.detach()
    #expect(!capture.isAttached)
    let recording = MicrophoneCapture(writer: writer, onFailure: { _ in })
    #expect(recording.isAttached)
    #expect(!MicrophoneMonitor.shared.active && MicrophoneMonitor.shared.deviceUID == nil)
    let borrowed = MicrophoneMonitor.shared.borrow(deviceID: "any", writer: writer, onFailure: { _ in })
    #expect(!borrowed)
    MicrophoneMonitor.shared.release()
    #expect(CameraMonitor.shared.borrowFeed(for: "any", format: nil) == nil)
}

/// 音波按"比底噪响多少"显示：安静与环境噪声为 0，说话明显起来；底噪读数更低立刻跟下去、更高只慢慢抬。
@Test func microphoneMeterIsRelativeToTheNoiseFloor() {
    #expect(MicrophoneMonitor.displayLevel(decibels: -55, floor: -55) == 0)
    #expect(MicrophoneMonitor.displayLevel(decibels: -40, floor: -42) == 0)
    #expect(abs(MicrophoneMonitor.displayLevel(decibels: -25, floor: -42) - 11 / 24) < 0.001)
    #expect(MicrophoneMonitor.displayLevel(decibels: -10, floor: -42) == 1)
    #expect(MicrophoneMonitor.updatedFloor(nil, reading: -40) == -40)
    #expect(MicrophoneMonitor.updatedFloor(-40, reading: -50) == -50)
    #expect(abs(MicrophoneMonitor.updatedFloor(-40, reading: -20) - -39.995) < 0.0001)
}

/// 停止立即返回且之后不再交样本：没起来的采集停一下也不出错。
@Test func stoppingReturnsImmediately() {
    let capture = MicrophoneCapture(writer: nil, onFailure: { _ in })
    let started = ContinuousClock.now
    capture.stop(); capture.stop()
    #expect(ContinuousClock.now - started < .milliseconds(50))
}

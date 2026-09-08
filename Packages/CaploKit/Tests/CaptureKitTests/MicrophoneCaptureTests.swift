import AVFoundation
import CoreAudio
import CoreMedia
import Testing
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
    #expect(MicrophoneCapture.audioDeviceID(forUID: uid) == device)
    #expect(!MicrophoneCapture.isSelectableMicrophone(uid: uid))
    #expect(MicrophoneCapture.isSelectableMicrophone(uid: "caplo-no-such-device"))
}

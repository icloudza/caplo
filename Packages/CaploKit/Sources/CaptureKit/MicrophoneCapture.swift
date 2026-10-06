@preconcurrency import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import CoreMedia
import os

/// 麦克风采集：录制条试听（只算电平）和录制写盘共用，两条引擎按顺序尝试。
/// 1. Apple 语音处理 I/O 单元（AUVoiceProcessingIO）：系统的麦克风模式（语音突显 / 宽谱）只作用于走这个单元的采集
///    （WWDC 明确"要用麦克风模式必须采用 AUVoiceIO"），它自带回声消除与降噪，系统给什么就录什么。它只认系统默认输入 / 输出，
///    所以使用期间把默认输入切到所选麦克风、停止时恢复；输入与输出两侧的客户端格式必须一致（否则 -10875），输出侧只渲染静音。
/// 2. AVCaptureSession：语音处理单元起不来时的退路，指定设备即开流，但系统麦克风模式对它无效。
/// 两条路都不做任何自己的处理；回声消除与降噪的离线版本在编辑器里（`VoiceProcessor`）。
final class MicrophoneCapture: @unchecked Sendable {
    enum Engine: String { case voiceProcessing = "语音处理单元", session = "采集会话" }
    /// 写入器的麦克风轨按 48 kHz 单声道浮点建；两条引擎都交这个格式（会话引擎按原生格式采集后转换）。
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true)!
    /// 所有实例共用一条串行队列：停止（含恢复系统默认输入）与下一次启动（切默认输入）必须按先后顺序执行，
    /// 否则异步停止的恢复会盖掉新一路刚切好的设备。
    private static let queue = DispatchQueue(label: "com.caplo.microphone", qos: .userInitiated)
    private var queue: DispatchQueue { Self.queue }
    /// 一喊停就立刻生效（不再交样本、不再报电平），拆引擎在队列上异步做，不卡调用方（主线程）。
    private let halted = OSAllocatedUnfairLock(initialState: false)
    /// 写盘出口：录制器可以随时挂上 / 摘下（借用试听中的采集时引擎不重启），音频线程读它要加锁。
    private struct Sink: Sendable { let writer: SegmentedCaptureWriter; let onFailure: @Sendable (String) -> Void }
    private let sink: OSAllocatedUnfairLock<Sink?>
    private let level: (@Sendable (Float) -> Void)?
    private let onFailure: @Sendable (String) -> Void
    private var voice: VoiceIOEngine?
    private var session: SessionEngine?
    private(set) var engine: Engine?
    private var consumed = false
    private var stopped = false
    private var logged = false
    private var levelRange: (low: Float, high: Float, since: TimeInterval)?

    /// `writer` 为 nil 时只试听（算电平不写盘）；`level` 每个采样块回调一次 0…1 的电平，在音频线程调用。
    init(writer: SegmentedCaptureWriter?, level: (@Sendable (Float) -> Void)? = nil, onFailure: @escaping @Sendable (String) -> Void) {
        sink = OSAllocatedUnfairLock(initialState: writer.map { Sink(writer: $0, onFailure: { _ in }) })
        self.level = level; self.onFailure = onFailure
    }

    /// 录制器借用正在试听的采集：把写入器挂上去，之后的样本直接写盘；采集出错也通知录制器。
    func attach(writer: SegmentedCaptureWriter, onFailure: @escaping @Sendable (String) -> Void) {
        sink.withLock { $0 = Sink(writer: writer, onFailure: onFailure) }
    }
    /// 录制结束摘下写入器，采集继续只算电平。
    func detach() { sink.withLock { $0 = nil } }
    var isAttached: Bool { sink.withLock { $0 != nil } }

    /// `deviceID` 是 AVCaptureDevice 的 uniqueID（与 CoreAudio 设备 UID 一致）。两条引擎都起不来才抛错。
    func start(deviceID: String) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    guard !consumed else { throw RecordingError.message("麦克风会话已使用，请重新开始录制。") }
                    consumed = true
                    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                        throw RecordingError.message("麦克风访问未获允许，请在系统设置中开启权限。")
                    }
                    let device = Self.audioDeviceID(forUID: deviceID)
                    guard device != kAudioObjectUnknown, AVCaptureDevice(uniqueID: deviceID) != nil else { throw RecordingError.message("所选麦克风未连接。") }
                    let deliver: @Sendable (CMSampleBuffer, Float) -> Void = { [weak self] sample, value in self?.deliver(sample, level: value) }
                    let failure: @Sendable (String) -> Void = { [weak self] message in
                        self?.onFailure(message)
                        self?.sink.withLock { $0 }?.onFailure(message)
                    }
                    do {
                        let voice = VoiceIOEngine(deliver: deliver, onFailure: failure)
                        try voice.start(device: device)
                        self.voice = voice; engine = .voiceProcessing
                    } catch {
                        NSLog("Caplo：语音处理单元不可用（%@），麦克风改走采集会话；系统麦克风模式对它无效", error.localizedDescription)
                        let session = SessionEngine(deliver: deliver, onFailure: failure)
                        try session.start(deviceID: deviceID)
                        self.session = session; engine = .session
                    }
                    NSLog("Caplo：麦克风采集走%@", engine?.rawValue ?? "")
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// 立即返回：语音处理单元的拆除与默认输入设备的恢复要几十到几百毫秒，放到采集队列上异步做。
    func stop() {
        halted.withLock { $0 = true }
        queue.async { [self] in
            guard consumed, !stopped else { return }
            stopped = true
            voice?.stop(); voice = nil
            session?.stop(); session = nil
        }
    }

    /// 两条引擎的统一出口：样本已在主机时钟上、48 kHz 单声道浮点。
    private func deliver(_ sample: CMSampleBuffer, level value: Float) {
        guard !halted.withLock({ $0 }) else { return }
        logDiagnostics(sample, level: value)
        level?(value)
        guard let sink = sink.withLock({ $0 }) else { return }
        nonisolated(unsafe) let outgoing = sample
        sink.writer.queue.async { sink.writer.ingest(outgoing, role: .microphone) }
    }

    /// 第一块样本打印采集格式，之后每 5 秒打印一次电平范围，便于对照实机现象。
    private func logDiagnostics(_ sample: CMSampleBuffer, level: Float) {
        if !logged, let description = sample.formatDescription?.audioStreamBasicDescription {
            logged = true
            NSLog("Caplo：麦克风样本 %.0f Hz、%d 声道、%d 位%@", description.mSampleRate, description.mChannelsPerFrame, description.mBitsPerChannel,
                  description.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "浮点" : "整数")
        }
        let now = ProcessInfo.processInfo.systemUptime
        var range = levelRange ?? (level, level, now)
        range.low = min(range.low, level); range.high = max(range.high, level)
        if now - range.since >= 5 {
            NSLog("Caplo：麦克风电平 %.0f…%.0f dB", Self.decibels(level: range.low), Self.decibels(level: range.high))
            range = (level, level, now)
        }
        levelRange = range
    }

    // MARK: - 电平

    /// 样本的电平：按样本描述里的实际格式读首缓冲（32 位浮点 / 16 位整数 / 32 位整数），均方根换成分贝，
    /// -55 dB 以下为 0、-10 dB 及以上为 1（留出音乐这类持续大信号的余量，说话时柱子仍有起伏）。
    static func level(of sample: CMSampleBuffer) -> Float {
        guard let description = sample.formatDescription?.audioStreamBasicDescription else { return 0 }
        var listSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0,
                                                                        blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr || listSize > 0,
              listSize > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: listSize,
                                                                        blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr,
              let first = UnsafeMutableAudioBufferListPointer(list).first, let data = first.mData else { return 0 }
        defer { withExtendedLifetime(block) {} }
        return level(bytes: data, byteCount: Int(first.mDataByteSize), description: description)
    }

    static func level(bytes data: UnsafeMutableRawPointer, byteCount: Int, description: AudioStreamBasicDescription) -> Float {
        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var rms: Float = 0
        switch (isFloat, description.mBitsPerChannel) {
        case (true, 32):
            let count = byteCount / MemoryLayout<Float>.size
            guard count > 0 else { return 0 }
            vDSP_rmsqv(data.assumingMemoryBound(to: Float.self), 1, &rms, vDSP_Length(count))
        case (false, 16):
            let count = byteCount / MemoryLayout<Int16>.size
            guard count > 0 else { return 0 }
            var floats = [Float](repeating: 0, count: count)
            vDSP_vflt16(data.assumingMemoryBound(to: Int16.self), 1, &floats, 1, vDSP_Length(count))
            vDSP_rmsqv(floats, 1, &rms, vDSP_Length(count)); rms /= 32_768
        case (false, 32):
            let count = byteCount / MemoryLayout<Int32>.size
            guard count > 0 else { return 0 }
            var floats = [Float](repeating: 0, count: count)
            vDSP_vflt32(data.assumingMemoryBound(to: Int32.self), 1, &floats, 1, vDSP_Length(count))
            vDSP_rmsqv(floats, 1, &rms, vDSP_Length(count)); rms /= 2_147_483_648
        default: return 0
        }
        return decibelLevel(rms: rms)
    }

    static let levelFloor: Float = -55, levelCeiling: Float = -10
    static func decibelLevel(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels - levelFloor) / (levelCeiling - levelFloor)))
    }
    static func decibels(level: Float) -> Float { levelFloor + level * (levelCeiling - levelFloor) }

    // MARK: - 样本换算

    /// 采集样本 → 同格式的采样块（数据复制一份，不引用采集的块缓冲）。
    static func pcmBuffer(from sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    /// 采样块 → 指定时间戳的样本（需要转换时先转，帧数按采样率比例变化，起始时间戳不变）；样本数据复制进新的块缓冲。
    static func sampleBuffer(from buffer: AVAudioPCMBuffer, presentationTime: CMTime, converter: AVAudioConverter?) -> CMSampleBuffer? {
        var pcm = buffer
        if let converter {
            let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
            guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64) else { return nil }
            nonisolated(unsafe) var consumed = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if consumed { outStatus.pointee = .noDataNow; return nil }
                consumed = true; outStatus.pointee = .haveData; return buffer
            }
            guard status != .error else { return nil }
            pcm = output
        }
        guard pcm.frameLength > 0 else { return nil }
        return sampleBuffer(list: pcm.audioBufferList, frames: Int(pcm.frameLength), description: pcm.format.formatDescription, presentationTime: presentationTime)
    }

    /// 缓冲列表 → 样本：数据复制进新的块缓冲，时长按采样率。
    static func sampleBuffer(list: UnsafePointer<AudioBufferList>, frames: Int, description: CMAudioFormatDescription, presentationTime: CMTime) -> CMSampleBuffer? {
        guard frames > 0, let rate = description.audioStreamBasicDescription?.mSampleRate, rate > 0 else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)), presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: description, sampleCount: CMItemCount(frames),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sample) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                             flags: 0, bufferList: list) == noErr else { return nil }
        return sample
    }

    /// 系统默认输入设备的读写（语音处理单元只认默认输入）。
    static func defaultInputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr ? device : kAudioObjectUnknown
    }
    @discardableResult static func setDefaultInputDevice(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = device
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }

    /// 设备号 → CoreAudio UID。设备号每次开机可能不同，跨进程记账只能用 UID。
    static func uid(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: - 默认输入的借用记账

    /// 语音处理单元只认系统默认输入，使用期间要把它切到所选麦克风。切之前把"从哪切到哪"记进偏好，
    /// 正常停止时清掉；应用崩溃或被强退来不及恢复的话，下次启动按这条记录改回去（见 `restoreDefaultInputLeftBehind`）。
    static let switchedDefaultInputKey = "microphone.switchedDefaultInput"
    static func rememberSwitch(from previous: AudioDeviceID, to device: AudioDeviceID, defaults: UserDefaults = .standard) {
        guard let from = uid(of: previous), let to = uid(of: device) else { return }
        defaults.set(["from": from, "to": to], forKey: switchedDefaultInputKey)
    }
    static func forgetSwitch(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: switchedDefaultInputKey) }

    /// 上次运行借用了系统默认输入却没来得及还：如果默认输入还停在当时切过去的那个麦克风，就改回原来的设备。
    /// 用户之后自己换过默认输入的，尊重用户，只清记录。返回是否真的改回了。
    @discardableResult
    static func restoreDefaultInputLeftBehind(defaults: UserDefaults = .standard,
                                              current: () -> String? = { uid(of: defaultInputDevice()) },
                                              restore: (String) -> Bool = { setDefaultInputDevice(audioDeviceID(forUID: $0)) }) -> Bool {
        guard let record = defaults.dictionary(forKey: switchedDefaultInputKey) as? [String: String] else { return false }
        defaults.removeObject(forKey: switchedDefaultInputKey)
        guard let from = record["from"], let to = record["to"], from != to, current() == to else { return false }
        return restore(from)
    }

    // MARK: - 设备

    /// 能出现在麦克风列表里的设备：不是聚合设备、不是隐藏设备、有输入通道（系统会把临时聚合设备和扬声器的参考流当麦克风列出来）。
    /// 找不到设备号的一律保留，不误删。
    static func isSelectableMicrophone(uid: String) -> Bool {
        let device = audioDeviceID(forUID: uid)
        guard device != kAudioObjectUnknown else { return true }
        if property(device, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeAggregate { return false }
        if property(device, kAudioDevicePropertyIsHidden) == 1 { return false }
        return inputChannelCount(device) > 0
    }

    private static func property(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// CoreAudio 设备 UID → 设备号；找不到返回 kAudioObjectUnknown。
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID {
        var deviceID = kAudioObjectUnknown
        var reference = uid as CFString
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &reference) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), pointer, &size, &deviceID)
        }
        return status == noErr ? deviceID : kAudioObjectUnknown
    }
}


/// Apple 语音处理 I/O 单元（AUVoiceProcessingIO）采集：输入回调里向单元拉取处理后的麦克风，输出回调只渲染静音。
/// 客户端格式两侧都是 48 kHz 单声道浮点；时间戳来自单元给的主机时间；不压低其他应用的声音（录制的正是它们）。
final class VoiceIOEngine: @unchecked Sendable {
    private var unit: AudioUnit?
    private var restoreDefaultInput: AudioDeviceID?
    private var device = kAudioObjectUnknown
    private let format: AudioStreamBasicDescription
    private let description: CMAudioFormatDescription
    private let list: UnsafeMutablePointer<AudioBufferList>
    private let storage: UnsafeMutableRawPointer
    private let capacity: Int
    private let deliver: @Sendable (CMSampleBuffer, Float) -> Void
    private let onFailure: @Sendable (String) -> Void
    private var running = false
    /// 失败只报一次：断开、默认输入被改走、渲染持续出错可能前后脚到达。
    private let reported = OSAllocatedUnfairLock(initialState: false)
    /// 连续渲染失败的块数（只在音频线程读写）。偶发一两块失败是正常抖动，持续失败才算采集中断。
    private var renderFailures = 0
    /// 属性监听用独立队列：在回调所在的队列上移除监听可能与正在执行的回调互等。
    private let listenerQueue = DispatchQueue(label: "com.caplo.microphone.voice-listener")
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var aliveListener: AudioObjectPropertyListenerBlock?

    init(deliver: @escaping @Sendable (CMSampleBuffer, Float) -> Void, onFailure: @escaping @Sendable (String) -> Void) {
        self.deliver = deliver; self.onFailure = onFailure
        format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                             mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
                                             mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var asbd = format
        var created: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &created)
        description = created!
        capacity = 8192 * 4
        storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        list = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        list.pointee = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: storage))
    }
    deinit { storage.deallocate(); list.deallocate() }

    func start(device: AudioDeviceID) throws {
        self.device = device
        // 单元只认系统默认输入：使用期间切到所选麦克风，停止时恢复。
        let current = MicrophoneCapture.defaultInputDevice()
        if current != device {
            MicrophoneCapture.rememberSwitch(from: current, to: device)
            guard MicrophoneCapture.setDefaultInputDevice(device) else {
                MicrophoneCapture.forgetSwitch()
                throw RecordingError.message("无法把系统默认输入切到所选麦克风。")
            }
            restoreDefaultInput = current
            // 切换默认输入是异步生效的；紧接着建单元会抓到旧设备。这里在麦克风串行队列上，不占主线程。
            Thread.sleep(forTimeInterval: 0.2)
        }
        var componentDescription = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &componentDescription) else { restore(); throw RecordingError.message("系统没有语音处理单元。") }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance), "创建语音处理单元")
        guard let unit = instance else { restore(); throw RecordingError.message("创建语音处理单元失败。") }
        self.unit = unit
        do {
            var enabled: UInt32 = 1
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, UInt32(MemoryLayout<UInt32>.size)), "启用输入")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, UInt32(MemoryLayout<UInt32>.size)), "启用输出")
            var asbd = format
            let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, size), "设置输入格式")
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, size), "设置输出格式")
            if #available(macOS 14.0, *) {
                // 不压低其他应用的声音：录制的正是系统声音。
                var ducking = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: false, mDuckingLevel: .min)
                AudioUnitSetProperty(unit, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0, &ducking, UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size))
            }
            let reference = Unmanaged.passUnretained(self).toOpaque()
            var inputCallback = AURenderCallbackStruct(inputProc: voiceInputCallback, inputProcRefCon: reference)
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &inputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "设置输入回调")
            var outputCallback = AURenderCallbackStruct(inputProc: voiceOutputCallback, inputProcRefCon: reference)
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &outputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "设置输出回调")
            try check(AudioUnitInitialize(unit), "初始化语音处理单元")
            try check(AudioOutputUnitStart(unit), "启动语音处理单元")
            running = true
            listen()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        unlisten()
        if let unit {
            if running { AudioOutputUnitStop(unit) }
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil; running = false
        restore()
    }

    private func restore() {
        if let previous = restoreDefaultInput, MicrophoneCapture.defaultInputDevice() == device { MicrophoneCapture.setDefaultInputDevice(previous) }
        if restoreDefaultInput != nil { MicrophoneCapture.forgetSwitch() }
        restoreDefaultInput = nil
    }

    /// 单元跟着系统默认输入走：别人把默认输入换成别的设备，录到的就悄悄变成另一支麦克风。
    /// 这和"设备拔掉绝不静默改用其他输入"是同一条原则，按采集中断上报，由录制器收尾保存。
    /// 设备本身消失也在这里报一次（录制器另有 AVCaptureDevice 断开通知，重复上报只生效一次）。
    private func listen() {
        var defaultAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running, MicrophoneCapture.defaultInputDevice() != self.device else { return }
            self.fail("系统默认输入被换成了其他设备，为免录进别的麦克风，已停止麦克风采集。")
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, listenerQueue, defaultBlock) == noErr {
            defaultInputListener = defaultBlock
        }
        var aliveAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let aliveBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running else { return }
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var alive: UInt32 = 1
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(self.device, &address, 0, nil, &size, &alive) != noErr || alive == 0 { self.fail("麦克风已断开。") }
        }
        if AudioObjectAddPropertyListenerBlock(device, &aliveAddress, listenerQueue, aliveBlock) == noErr {
            aliveListener = aliveBlock
        }
    }

    private func unlisten() {
        if let block = defaultInputListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
        }
        if let block = aliveListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(device, &address, listenerQueue, block)
        }
        defaultInputListener = nil; aliveListener = nil
    }

    /// 上报离开音频线程：失败处理会切主线程、建任务，不能在实时回调里做。
    private func fail(_ message: String) {
        guard reported.withLock({ done in defer { done = true }; return !done }) else { return }
        let onFailure = onFailure
        DispatchQueue.global(qos: .userInitiated).async { onFailure(message) }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw RecordingError.message("\(step)失败（\(status)）。") }
    }

    /// 输入回调：向单元拉取这一块处理后的麦克风数据，算电平并封成主机时钟时间戳的样本。
    fileprivate func handleInput(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timestamp: UnsafePointer<AudioTimeStamp>, bus: UInt32, frames: UInt32) -> OSStatus {
        guard let unit, running else { return noErr }
        let bytes = Int(frames) * Int(format.mBytesPerFrame)
        guard bytes <= capacity else { return noErr }
        list.pointee.mBuffers.mDataByteSize = UInt32(bytes)
        list.pointee.mBuffers.mData = storage
        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, list)
        guard status == noErr else {
            // 约一秒（48 kHz 下每块 10 毫秒左右）一直拉不到数据才算中断；以前这里只把错误码还给单元，录到的是一段静默。
            renderFailures += 1
            if renderFailures == 100 { fail("麦克风采集中断（\(status)）。") }
            return status
        }
        renderFailures = 0
        let level = MicrophoneCapture.level(bytes: storage, byteCount: bytes, description: format)
        let presentation = timestamp.pointee.mFlags.contains(.hostTimeValid)
            ? CMClockMakeHostTimeFromSystemUnits(timestamp.pointee.mHostTime) : CMClockGetTime(CMClockGetHostTimeClock())
        if let sample = MicrophoneCapture.sampleBuffer(list: list, frames: Int(frames), description: description, presentationTime: presentation) {
            deliver(sample, level)
        }
        return noErr
    }
}

/// 输入回调（C 函数指针）：转给引擎。
private let voiceInputCallback: AURenderCallback = { refCon, flags, timestamp, bus, frames, _ in
    Unmanaged<VoiceIOEngine>.fromOpaque(refCon).takeUnretainedValue().handleInput(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
}

/// 输出回调：只渲染静音，不回放麦克风也不放别的声音。
/// 只把缓冲清零、不标"输出是静音"：标了之后单元会跳过下行处理，实机日志里出现 "failed to run downlink DSP (state fault)"。
private let voiceOutputCallback: AURenderCallback = { _, _, _, _, _, ioData in
    if let ioData {
        for buffer in UnsafeMutableAudioBufferListPointer(ioData) { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
    }
    return noErr
}

/// AVCaptureSession 采集：不指定输出格式（系统按设备原生格式给），交出去前转成 48 kHz 单声道浮点，时间戳换到主机时钟。
final class SessionEngine: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.caplo.microphone.session", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let deliver: @Sendable (CMSampleBuffer, Float) -> Void
    private let onFailure: @Sendable (String) -> Void
    private var observer: NSObjectProtocol?
    private var converter: AVAudioConverter?
    private var converterFormat: AVAudioFormat?

    init(deliver: @escaping @Sendable (CMSampleBuffer, Float) -> Void, onFailure: @escaping @Sendable (String) -> Void) {
        self.deliver = deliver; self.onFailure = onFailure
    }

    func start(deviceID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else { throw RecordingError.message("所选麦克风未连接。") }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        do {
            defer { session.commitConfiguration() }
            guard session.canAddInput(input) else { throw RecordingError.message("无法使用所选麦克风。") }
            session.addInput(input)
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw RecordingError.message("无法建立麦克风输出。") }
            session.addOutput(output)
        }
        session.startRunning()
        guard session.isRunning else { throw RecordingError.message("麦克风会话未能启动。") }
        observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "采集出错"
            self?.onFailure("麦克风采集中断：\(reason)")
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        output.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let formatDescription = sampleBuffer.formatDescription else { return }
        let level = MicrophoneCapture.level(of: sampleBuffer)
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let clock: CMClock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        let presentation = CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock())
        if converterFormat != format {
            converterFormat = format
            converter = format.sampleRate == MicrophoneCapture.targetFormat.sampleRate && format.channelCount == 1 ? nil : AVAudioConverter(from: format, to: MicrophoneCapture.targetFormat)
        }
        guard let pcm = MicrophoneCapture.pcmBuffer(from: sampleBuffer, format: format),
              let sample = MicrophoneCapture.sampleBuffer(from: pcm, presentationTime: presentation, converter: converter) else { return }
        deliver(sample, level)
    }
}

/// 系统麦克风模式（标准 / 语音突显 / 宽谱）：由用户在控制中心选择，作用于本进程正在进行的麦克风采集；
/// 应用只能读取当前模式、观察它的变化并弹出系统的选择面板。名称与系统面板一致。
@MainActor @Observable public final class MicrophoneModes: NSObject {
    public static let shared = MicrophoneModes()
    public private(set) var current: AVCaptureDevice.MicrophoneMode = AVCaptureDevice.activeMicrophoneMode
    public var currentName: String { Self.name(current) }
    private var observing = false

    public static func name(_ mode: AVCaptureDevice.MicrophoneMode) -> String {
        switch mode {
        case .standard: "标准"
        case .wideSpectrum: "宽谱"
        case .voiceIsolation: "语音突显"
        @unknown default: "未知"
        }
    }
    public static func showSystemPicker() { AVCaptureDevice.showSystemUserInterface(.microphoneModes) }

    /// 开始跟随系统：类属性支持键值观察；试听或录制启动时再主动刷新一次。
    public func startObserving() {
        refresh()
        guard !observing else { return }
        observing = true
        (AVCaptureDevice.self as AnyObject).addObserver(self, forKeyPath: "activeMicrophoneMode", options: [.new], context: nil)
    }
    /// 只在真的变了才写：键值观察可能重复通知，无谓的写入会让观察它的界面重绘。
    public func refresh() {
        let mode = AVCaptureDevice.activeMicrophoneMode
        if mode != current { current = mode }
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "activeMicrophoneMode" else { return }
        Task { @MainActor in self.refresh() }
    }
}

/// 应用启动时调用：上次运行借走了系统默认输入却没来得及还（崩溃、强退）时把它改回去。
public enum MicrophoneDefaultInput {
    public static func restoreIfLeftBehind() { MicrophoneCapture.restoreDefaultInputLeftBehind() }
}

import CoreMedia

/// 不同音视频流先换算到同一个主机时钟，再进入分段写入器；不能直接假设两条流时间原点相同。
/// 仅复制样本时间信息，像素和 PCM 数据保持共享，避免引入全帧数据复制。
enum MediaClockBridge {
    static func retime(_ sample: CMSampleBuffer, from source: CMClockOrTimebase, to destination: CMClockOrTimebase = CMClockGetHostTimeClock()) throws -> CMSampleBuffer {
        if CFEqual(source, destination) { return sample }
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr, count > 0 else {
            throw RecordingError.message("无法读取采集样本的时间信息。")
        }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: nil) == noErr else {
            throw RecordingError.message("无法读取完整采集时序。")
        }
        for index in timings.indices {
            let original = timings[index]
            let pts = CMSyncConvertTime(original.presentationTimeStamp, from: source, to: destination)
            guard pts.isNumeric else { throw RecordingError.message("采集时钟无法同步。") }
            timings[index].presentationTimeStamp = pts
            if original.duration.isNumeric {
                timings[index].duration = CMSyncConvertTime(original.presentationTimeStamp + original.duration, from: source, to: destination) - pts
            }
            if original.decodeTimeStamp.isNumeric {
                timings[index].decodeTimeStamp = CMSyncConvertTime(original.decodeTimeStamp, from: source, to: destination)
            }
        }
        var output: CMSampleBuffer?
        let result = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &output)
        guard result == noErr, let output else { throw RecordingError.message("无法对齐音视频样本。") }
        return output
    }
}

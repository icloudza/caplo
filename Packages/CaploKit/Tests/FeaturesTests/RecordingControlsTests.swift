import Foundation
import Testing
@testable import Features

/// 计时读数按十分之一秒四舍五入：节拍时刻算出的 0.2999… 显示 .3；59.96 进位到 01:00.0；负数按 0。
@Test func recordingTimecodeRoundsToTenths() {
    #expect(RecordingControls.timecode(0) == "00:00.0")
    #expect(RecordingControls.timecode(0.29999) == "00:00.3")
    #expect(RecordingControls.timecode(14.3) == "00:14.3")
    #expect(RecordingControls.timecode(59.96) == "01:00.0")
    #expect(RecordingControls.timecode(61.04) == "01:01.0")
    #expect(RecordingControls.timecode(-2) == "00:00.0")
}

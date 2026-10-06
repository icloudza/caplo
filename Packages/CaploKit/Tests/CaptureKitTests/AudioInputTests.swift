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


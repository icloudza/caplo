import Foundation
import Testing
@testable import EditingCore

@Test func audioMuteSoloPreserveGainAndDecodeLegacySettings() throws {
    var levels = try JSONDecoder().decode(AudioLevels.self, from: Data(#"{"system":0.6,"microphone":0.3}"#.utf8))
    #expect(levels.muted.isEmpty && levels.solo.isEmpty)
    #expect(levels.effectiveGain(for: .system) == 0.6)
    levels.solo = [.microphone]
    #expect(levels.effectiveGain(for: .system) == 0)
    #expect(levels.effectiveGain(for: .microphone) == 0.3)
    levels.solo.insert(.system)
    #expect(levels.effectiveGain(for: .system) == 0.6)
    levels.muted.insert(.microphone)
    #expect(levels.effectiveGain(for: .microphone) == 0)
    #expect(levels.microphone == 0.3)
    let reopened = try JSONDecoder().decode(AudioLevels.self, from: JSONEncoder().encode(levels))
    #expect(reopened == levels)
    levels.muted.remove(.microphone); levels.solo.removeAll()
    #expect(levels.effectiveGain(for: .microphone) == 0.3)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(AudioLevels.self, from: Data(#"{"system":0.6,"microphone":0.3,"solo":["unknown"]}"#.utf8))
    }
}

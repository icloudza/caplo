import Foundation
import Testing
@testable import EditingCore

private func sample(_ time: Double, _ kind: PointerSample.Kind = .move, _ x: Double = 0.3, _ shape: PointerShape = .arrow) -> PointerSample {
    var sample = PointerSample(time: time, x: x, y: 0.4, kind: kind)
    sample.shape = shape; sample.button = 0; return sample
}

@Test func heldPressReleasesContinuouslyAndDoesNotLeakAcrossCuts() {
    let appearance = PointerAppearance(events: [sample(0), sample(1, .click), sample(2, .drag), sample(3, .release)])
    var effects = PointerEffects(); effects.bounce = 0.3
    func frame(_ time: Double, start: Double = 0) -> PointerFrame {
        var result = PointerFrame(); appearance.apply(to: &result, time: time, start: start, end: 4, effects: effects); return result
    }
    #expect(abs(frame(2.5).scale - 0.7) < 0.000001)
    #expect(abs(frame(3.0001).scale - frame(3).scale) < 0.000001)
    #expect(frame(3.2).scale == 1)
    #expect(frame(2.5, start: 2).scale == 1)
}

@Test func shapeBlendEndsAtClipEndAndOldOverrideIsIgnored() throws {
    let appearance = PointerAppearance(events: [sample(0), sample(1, .move, 0.3, .pointer)])
    var effects = PointerEffects(), frame = PointerFrame()
    appearance.apply(to: &frame, time: 1.05, start: 0, end: 1.1, effects: effects)
    #expect(frame.previousShape == .arrow && abs(frame.shapeMix - 0.5) < 0.00001)
    frame = PointerFrame(); effects = try JSONDecoder().decode(PointerEffects.self, from: Data(#"{"shapeOverride":"text"}"#.utf8))
    appearance.apply(to: &frame, time: 1.05, start: 0, end: 2, effects: effects)
    #expect(frame.shape == .pointer && frame.previousShape == .arrow && frame.shapeMix < 1)
    #expect(!String(decoding: try JSONEncoder().encode(effects), as: UTF8.self).contains("shapeOverride"))
}

@Test func idleAnticipatesMovementIgnoresJitterAndDoesNotFlashAtCut() {
    let events = (0...300).map { index in sample(Double(index) / 60, .move, index < 240 ? 0.3 + (index % 2 == 0 ? 0.001 : 0) : 0.5) }
    let appearance = PointerAppearance(events: events)
    var effects = PointerEffects(); effects.hideIdle = true
    func opacity(_ time: Double, end: Double = 5) -> Double {
        var frame = PointerFrame(); appearance.apply(to: &frame, time: time, start: 0, end: end, effects: effects); return frame.opacity
    }
    #expect(opacity(3) == 0)
    #expect(opacity(3.85) > 0 && opacity(3.85) < 1)
    #expect(opacity(4) == 1)
    #expect(opacity(3.85, end: 3.9) == 0)
}

@Test func longStationaryPressRemainsVisible() {
    let events = (0...360).map { index in sample(Double(index) / 60, index == 60 ? .click : index == 300 ? .release : .move) }
    let appearance = PointerAppearance(events: events)
    var effects = PointerEffects(); effects.hideIdle = true; effects.bounce = 0.3
    var frame = PointerFrame()
    appearance.apply(to: &frame, time: 4, start: 0, end: 6, effects: effects)
    #expect(frame.opacity == 1 && abs(frame.scale - 0.7) < 0.00001)
}

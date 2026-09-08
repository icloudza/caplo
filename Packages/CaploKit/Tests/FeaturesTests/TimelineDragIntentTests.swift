import CoreGraphics
import Testing
@testable import Features

struct TimelineDragIntentTests {
    @Test func clickingOrMovingWithinTheDeadZoneDoesNotStartADrag() {
        for point in [CGPoint.zero, CGPoint(x: 7.9, y: 0), CGPoint(x: 8, y: 0), CGPoint(x: 0, y: -8), CGPoint(x: 4, y: 4)] {
            #expect(!TimelineDragIntent.shouldBegin(from: .zero, to: point))
            #expect(TimelineDragIntent.displacement(from: .zero, to: point) == .zero)
        }
    }

    @Test func crossingTheThresholdStartsWithOnlyTheExcessDisplacement() {
        let point = CGPoint(x: 8.25, y: 0)
        #expect(TimelineDragIntent.shouldBegin(from: .zero, to: point))
        #expect(TimelineDragIntent.displacement(from: .zero, to: point) == CGPoint(x: 0.25, y: 0))
        #expect(TimelineDragIntent.displacement(from: .zero, to: CGPoint(x: 8.001, y: 0)).x < 0.002)
    }

    @Test func resistanceIsRadialAndPreservesTheDirection() {
        let displacement = TimelineDragIntent.displacement(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 112, y: 216))
        #expect(abs(displacement.x - 7.2) < 0.000001)
        #expect(abs(displacement.y - 9.6) < 0.000001)
        let reverse = TimelineDragIntent.displacement(from: CGPoint(x: 112, y: 216), to: CGPoint(x: 100, y: 200))
        #expect(reverse == CGPoint(x: -displacement.x, y: -displacement.y))
    }

    @Test func aFastDragStartsImmediatelyWithoutWaitingForALongPress() {
        let point = CGPoint(x: 100, y: 0)
        #expect(TimelineDragIntent.shouldBegin(from: .zero, to: point))
        #expect(TimelineDragIntent.displacement(from: .zero, to: point) == CGPoint(x: 92, y: 0))
    }

    @Test func returningInsideTheDeadZoneRestoresZeroWithoutAccumulatingMovement() {
        let origin = CGPoint(x: 200, y: 50)
        let farther = TimelineDragIntent.displacement(from: origin, to: CGPoint(x: 200, y: 70))
        #expect(farther == CGPoint(x: 0, y: 12))
        #expect(TimelineDragIntent.displacement(from: origin, to: CGPoint(x: 200, y: 60)) == CGPoint(x: 0, y: 2))
        #expect(TimelineDragIntent.displacement(from: origin, to: CGPoint(x: 200, y: 57)) == .zero)
        #expect(TimelineDragIntent.displacement(from: origin, to: origin) == .zero)
        #expect(TimelineDragIntent.displacement(from: origin, to: CGPoint(x: 200, y: 70)) == farther)
    }

    @Test func callersCanChooseAnotherDeadZoneWithoutChangingCoordinates() {
        let point = CGPoint(x: 5, y: 0)
        #expect(!TimelineDragIntent.shouldBegin(from: .zero, to: point))
        #expect(TimelineDragIntent.shouldBegin(from: .zero, to: point, threshold: 4))
        #expect(TimelineDragIntent.displacement(from: .zero, to: point, threshold: 4) == CGPoint(x: 1, y: 0))
        #expect(TimelineDragIntent.displacement(from: .zero, to: point, threshold: 0) == point)
        #expect(TimelineDragIntent.displacement(from: .zero, to: point, threshold: -1) == point)
    }

    @Test func invalidInputCannotStartADragOrProduceInvalidGeometry() {
        for point in [CGPoint(x: Double.nan, y: 0), CGPoint(x: 0, y: Double.infinity)] {
            #expect(!TimelineDragIntent.shouldBegin(from: .zero, to: point))
            #expect(!TimelineDragIntent.shouldBegin(from: point, to: .zero))
            #expect(TimelineDragIntent.displacement(from: .zero, to: point) == .zero)
        }
        for threshold in [Double.nan, .infinity] {
            #expect(!TimelineDragIntent.shouldBegin(from: .zero, to: CGPoint(x: 100, y: 0), threshold: threshold))
            #expect(TimelineDragIntent.displacement(from: .zero, to: CGPoint(x: 100, y: 0), threshold: threshold) == .zero)
        }
    }
}

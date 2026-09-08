import CoreGraphics
import EditingCore
import Testing
@testable import Features

struct TimelineInteractionGeometryTests {
    @Test(arguments: [0.25, 1.0, 15.0, 60.0])
    func shortBlocksKeepAnOperableWidthAtEveryZoom(scale: Double) {
        let rect = TimelineInteractionGeometry.blockRect(start: 3, duration: 1.0 / 30,
                                                         scale: scale, offset: 1, header: 64, y: 34, height: 30)
        #expect(rect.width == 44)
        #expect(rect.height == 30)
        #expect(TimelineInteractionGeometry.hitEdge(at: CGPoint(x: rect.midX, y: rect.midY), rect: rect) == .body)
        #expect(TimelineInteractionGeometry.hitEdge(at: CGPoint(x: rect.minX + 3, y: rect.midY), rect: rect) == .leading)
        #expect(TimelineInteractionGeometry.hitEdge(at: CGPoint(x: rect.maxX - 3, y: rect.midY), rect: rect) == .trailing)
    }

    @Test func visibleHandleSlopWorksOnBothSidesWithoutSelectingDistantEmptySpace() {
        let rect = TimelineInteractionGeometry.blockRect(start: 2, duration: 0.04,
                                                         scale: 60, offset: 0, header: 64, y: 34, height: 30)
        // 边柄的外扩区域也必须能开始裁剪，不能落入时间线空白处的定位操作。
        for distance in [0.0, 1.0, 3.5] {
            #expect(TimelineInteractionGeometry.hitEdge(at: CGPoint(x: rect.minX - distance, y: rect.midY), rect: rect) == .leading)
            #expect(TimelineInteractionGeometry.hitEdge(at: CGPoint(x: rect.maxX + distance, y: rect.midY), rect: rect) == .trailing)
        }
        #expect(TimelineInteractionGeometry.hitEdge(at: CGPoint(x: rect.minX - 4.5, y: rect.midY), rect: rect) == nil)
        #expect(TimelineInteractionGeometry.hitEdge(at: CGPoint(x: rect.maxX + 4.5, y: rect.midY), rect: rect) == nil)
        #expect(TimelineInteractionGeometry.hitEdge(at: CGPoint(x: rect.midX, y: rect.maxY + 3.5), rect: rect) == nil)
    }

    @Test func minimumDisplayWidthPreservesTheRealStartAndDuration() {
        var clip = VideoClip(sourceStart: 1.75, duration: 1.0 / 30)
        clip.timelineStart = 5.25
        let original = clip
        for scale in [0.25, 15.0, 120.0, 2400.0] {
            for offset in [0.0, 4.5, 5.5] {
                let rect = TimelineInteractionGeometry.blockRect(start: clip.timelineStart!, duration: clip.duration,
                                                                 scale: scale, offset: offset, header: 64, y: 34, height: 30)
                let representedStart = (rect.minX - 64) / scale + offset
                #expect(abs(representedStart - 5.25) < 0.000001)
                #expect(clip == original)
                if scale == 2400 { #expect(abs(rect.width - 80) < 0.000001) }
            }
        }
    }

    @Test func reorderSlotsRemoveTheSourceBeforeInsertingAndReturnToItsOriginalRow() {
        let original = ["a", "b", "c", "d", "e"]
        func reordered(at y: Double) -> [String] {
            let slot = TimelineInteractionGeometry.insertionSlot(y: y, top: 28, scroll: 0,
                                                                 rowHeight: 42, source: 2, count: original.count)
            var result = original
            let moving = result.remove(at: 2)
            result.insert(moving, at: slot)
            return result
        }
        // 在目标行上半部放到它前面，在下半部放到它后面；先删源行可避免向下时多跳一行。
        #expect(reordered(at: 28 + 42 * 0.25) == ["c", "a", "b", "d", "e"])
        #expect(reordered(at: 28 + 42 * 1.25) == ["a", "c", "b", "d", "e"])
        #expect(reordered(at: 28 + 42 * 3.75) == ["a", "b", "d", "c", "e"])
        #expect(reordered(at: 28 + 42 * 4.75) == ["a", "b", "d", "e", "c"])
        #expect(reordered(at: 28 + 42 * 2.25) == original)
        #expect(reordered(at: 28 + 42 * 2.75) == original)
    }

    @Test func verticalScrollingPreservesTheContentInsertionSlot() {
        let contentY = 28 + 42 * 3.25
        let unscrolled = TimelineInteractionGeometry.insertionSlot(y: contentY, top: 28, scroll: 0,
                                                                   rowHeight: 42, source: 0, count: 7)
        #expect(unscrolled == 2)
        for scroll in [21.0, 42.0, 84.0] {
            let scrolled = TimelineInteractionGeometry.insertionSlot(y: contentY - scroll, top: 28, scroll: scroll,
                                                                     rowHeight: 42, source: 0, count: 7)
            #expect(scrolled == unscrolled)
        }
    }

    @Test func reorderClampsToTheFirstAndLastAvailableSlot() {
        #expect(TimelineInteractionGeometry.insertionSlot(y: -500, top: 28, scroll: 0, rowHeight: 42, source: 2, count: 5) == 0)
        #expect(TimelineInteractionGeometry.insertionSlot(y: 5000, top: 28, scroll: 0, rowHeight: 42, source: 2, count: 5) == 4)
        #expect(TimelineInteractionGeometry.insertionSlot(y: 100, top: 28, scroll: 0, rowHeight: 42, source: 0, count: 1) == 0)
    }
}

import Testing
@testable import Features

struct TimelinePlaybackFollowTests {
    @Test func staysStillUntilTheRightThresholdThenMovesWithoutPaging() {
        var follow = TimelinePlaybackFollow()
        #expect(follow.advance(offset: 0, playhead: 7.99, visibleDuration: 10, elapsed: 1.0 / 60) == 0)
        let first = follow.advance(offset: 0, playhead: 8, visibleDuration: 10, elapsed: 1.0 / 60)
        #expect(first > 0 && first < 0.1)
        // 首次移动后播放头已退回 80% 阈值以内，跟随仍需继续，不能每隔几帧重新激活。
        let second = follow.advance(offset: first, playhead: 8, visibleDuration: 10, elapsed: 1.0 / 60)
        #expect(second > first && second < 0.5)
    }

    @Test func identicalElapsedTimeHasTheSameStationaryResponseAtDifferentRefreshRates() {
        func position(at fps: Int) -> Double {
            var follow = TimelinePlaybackFollow(), offset = 0.0
            for _ in 0..<fps {
                offset = follow.advance(offset: offset, playhead: 8, visibleDuration: 10, elapsed: 1 / Double(fps))
            }
            return offset
        }
        let values = [30, 60, 120].map(position)
        #expect(values.allSatisfy { abs($0 - values[0]) < 0.000001 })
        #expect(values.allSatisfy { $0 > 0.499 && $0 <= 0.5 })
    }

    @Test func movingPlaybackStaysSmoothAndNearlyIdenticalAcrossRefreshRates() {
        func position(at fps: Int) -> Double {
            var follow = TimelinePlaybackFollow(), offset = 0.0
            for frame in 1...(fps * 2) {
                let playhead = 8 + Double(frame) / Double(fps)
                let next = follow.advance(offset: offset, playhead: playhead, visibleDuration: 10, elapsed: 1 / Double(fps))
                #expect(next > offset)
                #expect(next - offset < 0.2)
                #expect(next < playhead - 7.5)
                offset = next
            }
            return offset
        }
        let values = [30, 60, 120].map(position)
        // 帧末采样移动目标会有不到半个低刷新率帧的差异，不能积累为速度或整页位置差。
        #expect(values.allSatisfy { abs($0 - values[0]) < 0.015 })
    }

    @Test func aPlayheadLeftOfTheViewportReturnsSmoothlyAndSettlesExactly() {
        var follow = TimelinePlaybackFollow(), offset = 20.0
        let first = follow.advance(offset: offset, playhead: 5, visibleDuration: 10, elapsed: 1.0 / 60)
        #expect(first < offset && first > 15)
        offset = first
        for _ in 0..<180 {
            let next = follow.advance(offset: offset, playhead: 5, visibleDuration: 10, elapsed: 1.0 / 60)
            #expect(next >= 0 && next <= offset)
            offset = next
        }
        #expect(offset == 0)
    }

    @Test func resetLeavesManualPositionAloneUntilTheNextThresholdCrossing() {
        var follow = TimelinePlaybackFollow()
        let first = follow.advance(offset: 0, playhead: 8, visibleDuration: 10, elapsed: 1.0 / 60)
        follow.reset()
        #expect(follow.advance(offset: first, playhead: 8, visibleDuration: 10, elapsed: 1.0 / 60) == first)
        #expect(follow.advance(offset: first, playhead: 9, visibleDuration: 10, elapsed: 1.0 / 60) > first)
    }

    @Test func invalidGeometryDoesNotActivateFollowOrProduceANonfiniteOffset() {
        var follow = TimelinePlaybackFollow()
        #expect(follow.advance(offset: .nan, playhead: 9, visibleDuration: 10, elapsed: 1.0 / 60) == 0)
        #expect(follow.advance(offset: .infinity, playhead: 9, visibleDuration: 10, elapsed: 1.0 / 60) == 0)
        #expect(follow.advance(offset: 2, playhead: .nan, visibleDuration: 10, elapsed: 1.0 / 60) == 2)
        for visible in [0.0, -10, .nan, .infinity] {
            #expect(follow.advance(offset: 2, playhead: 50, visibleDuration: visible, elapsed: 1.0 / 60) == 2)
        }
        for elapsed in [0.0, -1, .nan, .infinity] {
            #expect(follow.advance(offset: 2, playhead: 50, visibleDuration: 10, elapsed: elapsed) == 2)
        }
        #expect(follow.advance(offset: 2, playhead: 7, visibleDuration: 10, elapsed: 1.0 / 60) == 2)
    }

    @Test func aLongBackgroundPauseCannotBecomeAnInstantPageJump() {
        var resumed = TimelinePlaybackFollow(), bounded = TimelinePlaybackFollow()
        let actual = resumed.advance(offset: 0, playhead: 30, visibleDuration: 10, elapsed: 600)
        let limited = bounded.advance(offset: 0, playhead: 30, visibleDuration: 10, elapsed: 1.0 / 15)
        #expect(actual == limited)
        #expect(actual > 0 && actual < 22.5 / 2)
    }
}

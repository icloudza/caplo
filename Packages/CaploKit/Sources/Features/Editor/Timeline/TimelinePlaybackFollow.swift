import Foundation

/// 播放进入视口右侧后保持连续跟随；手动滚动或结束播放由调用方重置，不在阈值附近反复启停。
struct TimelinePlaybackFollow {
    private var following = false

    mutating func reset() { following = false }

    mutating func advance(offset: Double, playhead: Double, visibleDuration: Double, elapsed: Double) -> Double {
        let current = offset.isFinite ? max(0, offset) : 0
        guard offset.isFinite, playhead.isFinite, visibleDuration.isFinite, visibleDuration > 0,
              elapsed.isFinite, elapsed > 0 else { return current }
        let position = max(0, playhead)
        if !following {
            guard position >= current + visibleDuration * 0.8 || position < current else { return current }
            following = true
        }

        let target = max(0, position - visibleDuration * 0.75)
        // 按真实帧间隔求指数响应，30 / 60 / 120 Hz 使用同一时间常数；长时间挂起只推进有限一步。
        let dt = min(elapsed, 1.0 / 15)
        let ease = -expm1(-dt / 0.12)
        let difference = target - current
        let epsilon = max(0.0000001, visibleDuration * 0.000001)
        if abs(difference) <= epsilon { return target }
        let next = current + difference * ease
        return abs(target - next) <= epsilon ? target : max(0, next)
    }
}

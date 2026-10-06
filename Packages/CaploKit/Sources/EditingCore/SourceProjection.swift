import Foundation

/// 源域叠加层（遮罩、文字）投影到成片时间轴的公共算法。
///
/// 一个片段分两截：
/// 1. **真有画面在走的那一截**（`playableDuration`）按 1:1 线性投影，剪辑怎么切都还钉在原始录像的那一帧上；
/// 2. **"保持末帧"的那一截**画面是冻住的，源时间不再往前走——所以这一截产出一条 `frozen` 段，
///    取值一律停在最后那一帧对应的源时刻。
///
/// 第 2 条以前是把整段（含保持区）一起线性拉伸的。素材只差几十毫秒时看不出来，
/// 但一帧素材拉长成好几秒的定格片段，拉伸就等于**在一张静止画面上把源素材演一遍**：
/// 源域的文字会在定格里重放一次，源域的敏感遮罩会提前走完、露出没打码的定格帧。
extension VideoEdit {
    /// 一条投影结果：成片起点、时长、这一段起点对应叠加层自身的第几秒、是不是冻住的。
    struct SourceProjection {
        let start: Double
        let duration: Double
        let offset: Double
        let frozen: Bool
    }

    /// 把源区间 `[low, high)` 投影到片段 `clip` 的某个可见段上。
    /// `base` 是片段在成片上的起点，`span` 是这个片段真正露出来的那一截（已解遮挡）。
    static func projectSource(low: Double, high: Double, clip: VideoClip, base: Double,
                              spanStart: Double, spanEnd: Double) -> [SourceProjection] {
        let s0 = spanStart - base, s1 = min(spanEnd - base, clip.duration)
        // 卡片不引用素材：源域的遮罩、文字、镜头都不投影到卡片上。
        guard clip.card == nil, s1 > s0 + 0.000_001, high > low else { return [] }
        let playable = max(0, min(clip.playableDuration, clip.duration))
        var result: [SourceProjection] = []

        let liveEnd = min(s1, playable)
        if liveEnd > s0 + 0.000_001 {
            let shownLower = clip.sourceStart + s0, shownUpper = clip.sourceStart + liveEnd
            let lower = max(shownLower, low), upper = min(shownUpper, high)
            if upper > lower + 0.000_001 {
                result.append(SourceProjection(start: base + s0 + (lower - shownLower), duration: upper - lower,
                                               offset: lower - low, frozen: false))
            }
        }

        let heldStart = max(s0, playable)
        guard s1 > heldStart + 0.000_001 else { return result }
        // 冻住的是最后那一帧，它自己也占一小段源时间；只要叠加层碰到这一帧就得跟着冻在画面上，
        // 而不是按它自己的时间继续走完。遮罩尤其只能这样：宁可多盖一会儿，也不能提前撤掉。
        let held = clip.sourceStart + playable, frame = min(max(0, playable), 1.0 / 24)
        guard high > held - frame, low < held + 0.000_001 else { return result }
        let pinned = max(low, min(held, high - 0.000_001))
        result.append(SourceProjection(start: base + heldStart, duration: s1 - heldStart,
                                       offset: pinned - low, frozen: true))
        return result
    }
}

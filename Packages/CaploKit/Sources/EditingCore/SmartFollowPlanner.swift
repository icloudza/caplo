import Foundation
import CoreGraphics

/// 智能跟随：提交目标安全区、点击保持与临界阻尼跟随；距离自适应的目标平滑消除阈值跳变。
/// 录后可读到未来真实事件，因此前瞻采用已记录位置，避免速度外推在转弯时预测到错误方向。
///
/// 无点击的讲解镜头（手动添加、只跟指针）也走这里，为此的三处细化：
/// 1. 光标离开安全区时只把它带回内区（`innerZone`），而不是整轴回中，阅读扫视时相机几乎不动；
/// 2. 指针移动越快前瞻越远（读的是真实未来），相机在指针冲出视口之前就开始动；
/// 3. 光标已在视口之外时放宽加速度与限速追赶，追回来即恢复，上限随偏出距离连续变化，没有台阶。
enum SmartFollowPlanner {
    static func path(samples: [PointerSample], clicks: [PointerSample], start: Double, end: Double, scale: Double, style: AutoFocusStyle) -> [FocusKeyframe] {
        guard let first = clicks.first, end > start else { return [] }
        let initial = AutoFocus.clamp(CGPoint(x: first.x, y: first.y), scale: scale)
        var position = initial, committed = initial, filtered = initial, velocity = CGPoint.zero
        var frames = [FocusKeyframe(time: 0, x: initial.x, y: initial.y, scale: scale, move: 0)]
        var sampleIndex = 0, clickIndex = 0
        let prediction = min(0.4, max(0, style.prediction ?? 0.16))
        let response = min(1.5, max(0.15, style.panResponse ?? 0.55))
        let dt = 1.0 / 120, length = end - start
        let steps = Int(ceil(length / dt))
        let outputStride = max(4, Int(ceil(Double(steps) / 190_000)))
        var lastTarget = initial
        let speedProbe = PointerSpeedProbe(samples: samples)
        for step in 1...steps {
            let local = min(length, Double(step) * dt), time = start + local
            // 速度自适应前瞻：0.05 秒内的真实位移换算成速度，每 1 画面宽 / 秒多看 0.12 秒，最多再多 0.28 秒。
            let lookahead = min(0.4, prediction + min(0.28, speedProbe.speed(at: time) * 0.12))
            let future = min(end, time + lookahead)
            while sampleIndex + 1 < samples.count && samples[sampleIndex + 1].time <= future { sampleIndex += 1 }
            var cursor: CGPoint?
            if sampleIndex < samples.count {
                let a = samples[sampleIndex]
                if a.kind != .exit, a.time <= future {
                    var p = CGPoint(x: a.x, y: a.y)
                    if sampleIndex + 1 < samples.count {
                        let b = samples[sampleIndex + 1], span = b.time - a.time
                        if b.kind != .exit, span > 0, span < 0.2 {
                            let weight = min(1, max(0, (future - a.time) / span))
                            p.x += (b.x - a.x) * weight; p.y += (b.y - a.y) * weight
                        }
                    }
                    cursor = p
                }
            }
            while clickIndex + 1 < clicks.count && clicks[clickIndex + 1].time - prediction <= time { clickIndex += 1 }
            let click = clicks[clickIndex]
            let holding = time >= click.time - prediction && time <= click.time + 0.4
            if local < length - style.easeOut {
                if holding {
                    let target = AutoFocus.clamp(CGPoint(x: click.x, y: click.y), scale: scale)
                    if hypot(target.x - committed.x, target.y - committed.y) > 0.035 { committed = target }
                } else if let cursor {
                    // 只对离开安全区的那个轴回中，且只回到内区边缘：移动量最小，阅读扫视时相机基本不动。
                    let safeRatio = min(0.95, max(0.2, style.safeZone))
                    let safeHalf = 0.5 / scale * safeRatio
                    let innerHalf = 0.5 / scale * min(safeRatio * 0.95, max(0, style.innerZone))
                    if abs(cursor.x - committed.x) > safeHalf { committed.x = cursor.x - (cursor.x > committed.x ? innerHalf : -innerHalf) }
                    if abs(cursor.y - committed.y) > safeHalf { committed.y = cursor.y - (cursor.y > committed.y ? innerHalf : -innerHalf) }
                    committed = AutoFocus.clamp(committed, scale: scale)
                }
                // 自适应指数平滑，按内容时间而非播放器帧率校正。
                let distance = hypot(committed.x - filtered.x, committed.y - filtered.y)
                let base = 0.08 + 0.24 * min(1, distance / 0.25)
                let factor = 1 - pow(1 - base, dt / (1.0 / 60))
                filtered.x += (committed.x - filtered.x) * factor
                filtered.y += (committed.y - filtered.y) * factor
                lastTarget = filtered
            }
            // 弹簧运动：速度保留，目标改变不会重启 ease-in。
            let omega = (6 / response) * (holding ? 1.15 : 1)
            let ax = omega * omega * (lastTarget.x - position.x) - 2 * omega * velocity.x
            let ay = omega * omega * (lastTarget.y - position.y) - 2 * omega * velocity.y
            // 追赶：光标（前瞻后的位置）已在视口之外时放宽加速度与限速，偏出越多放得越开，追回来即恢复。
            var maxAcceleration = 3.0, maxVelocity = 0.8
            if let cursor {
                let half = CGFloat(0.5 / scale) * 0.9
                let outside = max(abs(cursor.x - position.x) - half, abs(cursor.y - position.y) - half)
                if outside > 0 {
                    maxAcceleration += min(9, Double(outside) * 40)
                    maxVelocity += min(1.4, Double(outside) * 10)
                }
            }
            velocity.x += min(maxAcceleration, max(-maxAcceleration, ax)) * dt
            velocity.y += min(maxAcceleration, max(-maxAcceleration, ay)) * dt
            velocity.x = min(maxVelocity, max(-maxVelocity, velocity.x))
            velocity.y = min(maxVelocity, max(-maxVelocity, velocity.y))
            // 接近画面边界时提前减速，而不是撞上坐标 clamp 才突然停住。
            let margin = CGFloat(0.5 / scale)   // 明确为 CGFloat：旧编译器下 Double 与 CGFloat 混算会报 "*" 歧义
            velocity.x = min((1 - margin - position.x) * 4, max((margin - position.x) * 4, velocity.x))
            velocity.y = min((1 - margin - position.y) * 4, max((margin - position.y) * 4, velocity.y))
            position.x += velocity.x * dt; position.y += velocity.y * dt
            position = AutoFocus.clamp(position, scale: scale)
            if step % outputStride == 0 || step == steps {
                frames.append(FocusKeyframe(time: local, x: position.x, y: position.y, scale: scale, move: 0))
            }
        }
        // 真正静止的镜头无需保存密集轨迹；动态镜头保留采样速度，求值时二分插值。
        if frames.allSatisfy({ hypot($0.x - initial.x, $0.y - initial.y) < 0.001 }) { return [frames[0]] }
        return frames
    }
}


/// 指针瞬时速度（画面宽 / 秒）：取某时刻与其后 0.05 秒两点的真实位移；离屏或没有样本时视为静止。
struct PointerSpeedProbe {
    private let samples: [PointerSample]
    init(samples: [PointerSample]) { self.samples = samples }

    func speed(at time: Double) -> Double {
        guard let a = position(at: time), let b = position(at: time + 0.05) else { return 0 }
        return hypot(b.x - a.x, b.y - a.y) / 0.05
    }

    /// 相邻两个移动样本之间线性插值；跨越 exit 或相隔太久（> 0.2 秒）不插值。
    func position(at time: Double) -> CGPoint? {
        guard !samples.isEmpty else { return nil }
        var low = 0, high = samples.count
        while low < high { let middle = (low + high) / 2; if samples[middle].time <= time { low = middle + 1 } else { high = middle } }
        guard low > 0 else { return nil }
        let a = samples[low - 1]
        guard a.kind != .exit else { return nil }
        if low < samples.count {
            let b = samples[low], span = b.time - a.time
            if b.kind != .exit, span > 0, span < 0.2 {
                let weight = min(1, max(0, (time - a.time) / span))
                return CGPoint(x: a.x + (b.x - a.x) * weight, y: a.y + (b.y - a.y) * weight)
            }
        }
        return CGPoint(x: a.x, y: a.y)
    }
}

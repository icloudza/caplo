import Foundation
import CoreGraphics

/// 智能跟随：提交目标安全区、点击保持与临界阻尼跟随；距离自适应的目标平滑消除阈值跳变。
/// 录后可读到未来真实事件，因此前瞻采用已记录位置，避免速度外推在转弯时预测到错误方向。
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
        for step in 1...steps {
            let local = min(length, Double(step) * dt), time = start + local
            let future = min(end, time + prediction)
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
                    let safeHalf = 0.5 / scale * min(0.95, max(0.2, style.safeZone))
                    if abs(cursor.x - committed.x) > safeHalf { committed.x = cursor.x }
                    if abs(cursor.y - committed.y) > safeHalf { committed.y = cursor.y }
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
            velocity.x += min(3, max(-3, ax)) * dt
            velocity.y += min(3, max(-3, ay)) * dt
            let maxVelocity = 0.8
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

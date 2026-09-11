import Foundation
import CoreGraphics

/// 智能跟随（2026-09-11 起按 Cap 的骨架重写，公式与 scratchpad 的 focus-compare.html 逐行对应）。
///
/// 1. **目标由点击簇决定**：这一段里所有指针移动（点击也是移动）按时间顺序贪心装进包围盒，盒子不超过视口的
///    `clusterWidth` 宽、其 1.4 倍高；相机目标是盒子中心，指针不出盒子目标就不换。一串相近的点击就是一个盒子，
///    相机一次都不动——这就是"邻近连点导致过度跟随"的解。旧版把每次点击都当成新目标，离当前目标超过 3.5% 画面宽就换。
/// 2. **走位交给一根解析求解的弹簧**：Cap 默认刚度 200、阻尼 40、质量 2.25（ω₀ ≈ 9.43、ζ ≈ 0.94），每 8 毫秒换一次目标，
///    速度一直保留，没有加速度与速度上限。旧版的加速度上限 3 让相机挪四分之一画面要 0.8 秒，弹簧 0.35 秒就到。
///    「跟随平滑度」换算成 ω₀ 的倍数，0.55 正好落在 Cap 的默认值上。
/// 3. **取景中心参数化成 0…1 的行进比例**，天然出不了画面；靠边 `edgeSnap` 以内的目标直接把取景框贴到边上。
///
/// 离线规划知道全部未来，所以比 Cap 多两样：
/// 4. **提前对准**：每次换簇提前 `lead` 秒（默认 2/ω₀，即弹簧追动目标的稳态滞后）把目标换过去，相机到位时指针刚好也到。
///    Cap 只在倍率还是 1 的起手时预对准。「提前对准」滑块拖到 0 就是 Cap 原样。
/// 5. **跳过过路簇**：没有点击、停留不到 `passThrough` 秒的簇只是路过，时间并给下一个簇，相机径直去终点。
enum SmartFollowPlanner {
    /// Cap 的默认弹簧：stiffness 200、damping 40、mass 2.25。
    static let capOmega0 = (200.0 / 2.25).squareRoot()
    static let capZeta = 40.0 / (2 * (200.0 * 2.25).squareRoot())
    /// 靠边这么大比例以内的目标直接贴边（Cap 的 edge_snap_ratio 默认值）。
    static let edgeSnap = 0.25
    /// 过路簇的判定：无点击且占用（到下一个簇开始为止）短于此。
    static let passThrough = 0.25
    /// 弹簧步长（125 Hz，与 Cap 相同）。
    static let step = 0.008

    struct Cluster: Equatable {
        var minX: Double, maxX: Double, minY: Double, maxY: Double
        /// 簇内首末事件的时间；`start` 会被"跳过过路簇"和"起手对准"改早。
        var start: Double, last: Double
        var clicked: Bool
        var center: CGPoint { CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2) }
    }

    static func omega0(style: AutoFocusStyle) -> Double {
        let response = min(1.5, max(0.15, style.panResponse ?? 0.55))
        return capOmega0 * (0.55 / response)
    }
    static func lead(style: AutoFocusStyle) -> Double {
        min(0.4, max(0, style.prediction ?? 2 / omega0(style: style)))
    }
    static func clusterSize(style: AutoFocusStyle, scale: Double) -> (width: Double, height: Double) {
        let ratio = min(0.9, max(0.2, style.clusterWidth ?? 0.5))
        return (ratio / max(1, scale), min(0.95, ratio * 1.4) / max(1, scale))
    }

    /// 贪心包围盒 + 跳过过路簇。离屏（exit）样本不参与。
    static func clusters(samples: [PointerSample], start: Double, end: Double, scale: Double, style: AutoFocusStyle) -> [Cluster] {
        let box = clusterSize(style: style, scale: scale)
        var result: [Cluster] = []
        var current: Cluster?
        for sample in samples where sample.kind != .exit && sample.time >= start && sample.time <= end {
            if var cluster = current {
                let width = max(cluster.maxX, sample.x) - min(cluster.minX, sample.x)
                let height = max(cluster.maxY, sample.y) - min(cluster.minY, sample.y)
                if width <= box.width && height <= box.height {
                    cluster.minX = min(cluster.minX, sample.x); cluster.maxX = max(cluster.maxX, sample.x)
                    cluster.minY = min(cluster.minY, sample.y); cluster.maxY = max(cluster.maxY, sample.y)
                    cluster.last = sample.time
                    if sample.kind == .click { cluster.clicked = true }
                    current = cluster
                    continue
                }
                result.append(cluster)
            }
            current = Cluster(minX: sample.x, maxX: sample.x, minY: sample.y, maxY: sample.y,
                              start: sample.time, last: sample.time, clicked: sample.kind == .click)
        }
        if let current { result.append(current) }
        // 过路簇：把它的时间并给下一个簇，相机不再朝路上的位置起步。占用时长按"到下一个簇开始"算——
        // 一个孤零零的样本（指针停着没动）占用的是整段静止，不是过路。
        guard passThrough > 0, result.count > 1 else { return result }
        var kept: [Cluster] = []
        var carriedStart: Double?
        for (index, cluster) in result.enumerated() {
            var cluster = cluster
            if let carriedStart { cluster.start = carriedStart }
            if index + 1 < result.count, !cluster.clicked, result[index + 1].start - cluster.start < passThrough {
                carriedStart = cluster.start
                continue
            }
            carriedStart = nil
            kept.append(cluster)
        }
        return kept
    }

    /// 相机路径（画面归一化坐标，时间从 0 起）。
    /// - `initial`：接续上一段时相机已经在的位置，弹簧从这里出发；为 nil 时起手就对准第一个目标（Cap 的预对准）。
    /// - `aimAt`：起手要对准的时刻（自动镜头传首次点击）；这之前的簇是走向落点的路，并进落点那个簇。
    /// - `freezeTail`：末尾这么多秒不再换目标（拉远期间目标冻结，与 Cap 的 held_center 相同）。
    static func path(samples: [PointerSample], start: Double, end: Double, scale: Double, style: AutoFocusStyle,
                     initial: CGPoint? = nil, aimAt: Double? = nil, freezeTail: Double = 0) -> [FocusKeyframe] {
        guard end > start, scale.isFinite else { return [] }
        let amount = max(1, scale), margin = 0.5 / amount, travel = 1 - 2 * margin
        var clusters = clusters(samples: samples, start: start, end: end, scale: amount, style: style)
        if let aimAt, let index = clusters.firstIndex(where: { $0.start <= aimAt && aimAt <= $0.last })
            ?? clusters.lastIndex(where: { $0.start <= aimAt }), index > 0 {
            clusters[index].start = clusters[0].start
            clusters.removeFirst(index)
        }
        let omega0 = omega0(style: style), zeta = capZeta, lead = lead(style: style)
        func toTravel(_ value: Double) -> Double { travel > 0.000001 ? min(1, max(0, (value - margin) / travel)) : 0.5 }
        func toScreen(_ value: Double) -> Double { margin + min(1, max(0, value)) * travel }
        func snap(_ value: Double) -> Double {
            let low = edgeSnap, high = 1 - edgeSnap
            guard edgeSnap > 0, high > low else { return min(1, max(0, value)) }
            return min(1, max(0, (value - low) / (high - low)))
        }
        let fallback = initial.map { CGPoint(x: toTravel($0.x), y: toTravel($0.y)) } ?? CGPoint(x: 0.5, y: 0.5)
        func target(at time: Double) -> CGPoint {
            guard let cluster = clusters.last(where: { $0.start - lead <= time }) ?? clusters.first else { return fallback }
            let focus = cluster.center
            return CGPoint(x: snap(min(1, max(0, focus.x))), y: snap(min(1, max(0, focus.y))))
        }

        let length = end - start
        let steps = max(1, Int(ceil(length / step)))
        let outputStride = max(4, Int(ceil(Double(steps) / 190_000)))
        var position = initial.map { CGPoint(x: toTravel($0.x), y: toTravel($0.y)) } ?? target(at: start)
        var velocity = CGPoint.zero
        var frozen: CGPoint?
        var frames = [FocusKeyframe(time: 0, x: toScreen(position.x), y: toScreen(position.y), scale: scale, move: 0)]
        var pending: FocusKeyframe?
        for index in 1...steps {
            let local = min(length, Double(index) * step), time = start + local
            let goal: CGPoint
            if local >= length - freezeTail { goal = frozen ?? target(at: time); frozen = goal } else { goal = target(at: time) }
            spring(&position, &velocity, toward: goal, dt: step, omega0: omega0, zeta: zeta)
            position.x = min(1, max(0, position.x)); position.y = min(1, max(0, position.y))
            let frame = FocusKeyframe(time: local, x: toScreen(position.x), y: toScreen(position.y), scale: scale, move: 0)
            if index % outputStride == 0 || index == steps {
                if let last = frames.last, abs(frame.x - last.x) < 0.000_001, abs(frame.y - last.y) < 0.000_001, index != steps {
                    // 静止阶段不存密集帧，只记住最后一帧：一动起来先补上它，插值才不会把静止拉成缓慢漂移。
                    pending = frame
                } else {
                    if let held = pending { frames.append(held); pending = nil }
                    frames.append(frame)
                }
            }
        }
        // 真正静止的镜头无需保存轨迹。
        if frames.allSatisfy({ abs($0.x - frames[0].x) < 0.001 && abs($0.y - frames[0].y) < 0.001 }) { return [frames[0]] }
        return frames
    }

    // MARK: 弹簧（Cap spring_mass_damper.rs 的解析解）

    static func spring(_ position: inout CGPoint, _ velocity: inout CGPoint, toward target: CGPoint, dt: Double, omega0: Double, zeta: Double) {
        let (dx, vx) = solve(displacement: position.x - target.x, velocity: velocity.x, t: dt, omega0: omega0, zeta: zeta)
        let (dy, vy) = solve(displacement: position.y - target.y, velocity: velocity.y, t: dt, omega0: omega0, zeta: zeta)
        position = CGPoint(x: target.x + dx, y: target.y + dy)
        velocity = CGPoint(x: vx, y: vy)
        if hypot(dx, dy) < 0.000_01, hypot(vx, vy) < 0.000_1 { position = target; velocity = .zero }
    }

    /// 一维弹簧-质量-阻尼在 t 秒后的位移与速度：欠阻尼 / 过阻尼 / 临界三种解析解。
    static func solve(displacement: Double, velocity: Double, t: Double, omega0: Double, zeta: Double) -> (Double, Double) {
        let epsilon = 0.01
        if zeta < 1 - epsilon {
            let omegaD = omega0 * (1 - zeta * zeta).squareRoot()
            let decay = exp(-zeta * omega0 * t), cosine = cos(omegaD * t), sine = sin(omegaD * t)
            let a = displacement, b = (velocity + displacement * zeta * omega0) / max(omegaD, 0.0001)
            return (decay * (a * cosine + b * sine),
                    decay * ((b * omegaD - a * zeta * omega0) * cosine - (a * omegaD + b * zeta * omega0) * sine))
        }
        if zeta > 1 + epsilon {
            let root = (zeta * zeta - 1).squareRoot()
            let s1 = -omega0 * (zeta - root), s2 = -omega0 * (zeta + root), denominator = s1 - s2
            let c1 = (velocity - displacement * s2) / denominator, c2 = displacement - c1
            let e1 = exp(s1 * t), e2 = exp(s2 * t)
            return (c1 * e1 + c2 * e2, c1 * s1 * e1 + c2 * s2 * e2)
        }
        let decay = exp(-omega0 * t), a = displacement, b = velocity + displacement * omega0
        return (decay * (a + b * t), decay * (b - omega0 * (a + b * t)))
    }
}

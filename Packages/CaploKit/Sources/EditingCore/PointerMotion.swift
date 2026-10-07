import Foundation

/// 光标平滑用的一维阻尼振子：每个坐标轴一份，目标点每帧更新。
/// 每步按闭式解推进位置，步长大小不影响稳定性。
struct PointerSpring {
    var value: Double
    var velocity = 0.0

    /// 平滑档位 0…2 对应的物理参数。分两段线性插值：0…0.5 为跟手档，0.5…2 为顺滑档；
    /// 两段在 0.5 处取前一段端点，后一段质量起点略低，保持现有工程的手感不变。
    private struct Tuning { var stiffness: Double; var damping: Double; var mass: Double }
    private static let stiffnessGain = 1.12
    private static let responsive = (from: Tuning(stiffness: 760, damping: 34, mass: 0.85), to: Tuning(stiffness: 340, damping: 58, mass: 1.4))
    private static let gentle = (from: Tuning(stiffness: 340, damping: 58, mass: 1.35), to: Tuning(stiffness: 160, damping: 80, mass: 1.8))

    private static func tuning(smoothing: Double) -> Tuning {
        let s = min(2, max(0, smoothing))
        let (range, f) = s <= 0.5 ? (responsive, s / 0.5) : (gentle, (s - 0.5) / 1.5)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * f }
        return Tuning(stiffness: mix(range.from.stiffness, range.to.stiffness) * stiffnessGain,
                      damping: mix(range.from.damping, range.to.damping),
                      mass: mix(range.from.mass, range.to.mass))
    }

    /// 追动匀速目标时的稳态滞后（秒）= 阻尼 / 刚度，与质量无关；让目标提前这么多采样，平滑后的光标就压在真实位置上。
    static func lag(smoothing: Double) -> Double {
        let p = tuning(smoothing: smoothing)
        return p.damping / p.stiffness
    }

    /// 目标在本步内视为不变，偏差 e = value − target 按闭式解演化 dt。
    /// 记 ω = √(k/m)、ζ = c / (2√(km))、a = ζω：
    /// 欠阻尼用衰减正余弦，临界阻尼用 (A + Bt)·e^(−ωt)，过阻尼拆成两个衰减指数，避免 cosh / sinh 在大步长下溢出。
    /// 速度取步末之后 0.1 毫秒的位置差分；现有光标手感按这一取法标定，改成解析速度会让大跳点后的轨迹偏开几个像素。
    mutating func step(target: Double, dt: Double, smoothing: Double) {
        let p = Self.tuning(smoothing: smoothing)
        let omega = (p.stiffness / p.mass).squareRoot()
        let zeta = p.damping / (2 * (p.stiffness * p.mass).squareRoot())
        let a = zeta * omega
        let e0 = value - target, v0 = velocity
        let motion: Motion
        if abs(zeta - 1) < 1e-6 {
            motion = .critical(omega: omega, e0: e0, b: v0 + omega * e0)
        } else if zeta < 1 {
            let w = omega * (1 - zeta * zeta).squareRoot()
            motion = .oscillating(decay: a, w: w, e0: e0, b: (v0 + a * e0) / w)
        } else {
            // 两个实根 r = −a ± g（均为负），通解 e(t) = A·e^(r₁t) + B·e^(r₂t)。
            let g = omega * (zeta * zeta - 1).squareRoot()
            let r1 = -a + g, r2 = -a - g
            let A = (v0 - r2 * e0) / (r1 - r2)
            motion = .settling(r1: r1, r2: r2, A: A, B: e0 - A)
        }
        let probe = 0.0001
        let e = motion.offset(at: dt), next = target + e
        // 过阻尼 / 临界阻尼本不应越过目标；目标逐帧移动时残余速度会把值推过头，这里一旦越过就贴住目标并清零速度，防止来回晃。
        if zeta >= 1, (value <= target && next > target) || (value >= target && next < target) {
            value = target; velocity = 0
        } else {
            velocity = (motion.offset(at: dt + probe) - e) / probe
            value = next
        }
    }

    /// 本步的偏差曲线 e(t)，三种阻尼情形各存一组系数。
    private enum Motion {
        case critical(omega: Double, e0: Double, b: Double)
        case oscillating(decay: Double, w: Double, e0: Double, b: Double)
        case settling(r1: Double, r2: Double, A: Double, B: Double)

        func offset(at t: Double) -> Double {
            switch self {
            case let .critical(omega, e0, b): return exp(-omega * t) * (e0 + b * t)
            case let .oscillating(decay, w, e0, b): return exp(-decay * t) * (e0 * cos(w * t) + b * sin(w * t))
            case let .settling(r1, r2, A, B): return A * exp(r1 * t) + B * exp(r2 * t)
            }
        }
    }
}

/// 演示镜头的缓动曲线：CSS 风格的三次贝塞尔 (0,0)–(x1,y1)–(x2,y2)–(1,1)。
public enum DemoMotion {
    /// 给定横轴进度 time，求曲线上同一横坐标处的纵坐标。
    /// 控制点横坐标在 0…1 内时 x(u) 单调，用牛顿迭代求参数 u，越出当前区间或导数过小时退回区间中点，保证收敛。
    public static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ time: Double) -> Double {
        let x = max(0, min(1, time))
        if x == 0 || x == 1 { return x }
        // 多项式系数：p(u) = ((P·u + Q)·u + R)·u，R = 3·p1，Q = 3·(p2 − p1) − R，P = 1 − R − Q。
        func coefficients(_ p1: Double, _ p2: Double) -> (Double, Double, Double) {
            let r = 3 * p1, q = 3 * (p2 - p1) - r
            return (1 - r - q, q, r)
        }
        let (px, qx, rx) = coefficients(x1, x2), (py, qy, ry) = coefficients(y1, y2)
        func curveX(_ u: Double) -> Double { ((px * u + qx) * u + rx) * u }
        func slopeX(_ u: Double) -> Double { (3 * px * u + 2 * qx) * u + rx }

        var low = 0.0, high = 1.0, u = x
        for _ in 0..<40 {
            let error = curveX(u) - x
            if abs(error) < 1e-12 { break }
            if error > 0 { high = u } else { low = u }
            let slope = slopeX(u)
            var next = slope > 1e-9 ? u - error / slope : .nan
            if !(next > low && next < high) { next = (low + high) / 2 }
            u = next
        }
        return ((py * u + qy) * u + ry) * u
    }

    public static func easeOut(_ time: Double) -> Double { bezier(0.16, 1, 0.3, 1, time) }
}

import Foundation

/// 解析弹簧与调参映射。
/// 本文件含 AGPL-3.0 移植代码：Copyright (C) 2026 webadderall；许可证原文见资源包 Licenses 目录（版权与许可声明按许可证要求保留）。
/// 原版权与许可证随 RenderKit 资源分发，固定来源提交见 Docs/鼠标功能融合.md。
struct PointerSpring {
    var value: Double
    var velocity = 0.0

    /// 平滑档位对应的弹簧常数（刚度、阻尼、质量）。
    static func constants(smoothing: Double) -> (stiffness: Double, damping: Double, mass: Double) {
        let s = min(2, max(0, smoothing))
        let n = s <= 0.5 ? s / 0.5 : (s - 0.5) / 1.5
        let stiffness = (s <= 0.5 ? 760 - n * 420 : 340 - n * 180) * 1.12
        let damping = (s <= 0.5 ? 34 + n * 24 : 58 + n * 22)
        let mass = (s <= 0.5 ? 0.85 + n * 0.55 : 1.35 + n * 0.45)
        return (stiffness, damping, mass)
    }
    /// 追动目标时的稳态滞后（秒）= 阻尼 / 刚度，与质量无关；让目标提前这么多采样，平滑后的光标就压在真实位置上。
    static func lag(smoothing: Double) -> Double {
        let c = constants(smoothing: smoothing)
        return c.damping / c.stiffness
    }

    mutating func step(target: Double, dt: Double, smoothing: Double) {
        let (stiffness, damping, mass) = Self.constants(smoothing: smoothing)
        let omega = sqrt(stiffness / mass), zeta = damping / (2 * sqrt(stiffness * mass))
        let delta = target - value, initialVelocity = -velocity
        func position(_ t: Double) -> Double {
            if zeta < 1 {
                let wd = omega * sqrt(1 - zeta * zeta)
                return target - exp(-zeta * omega * t) * (((initialVelocity + zeta * omega * delta) / wd) * sin(wd * t) + delta * cos(wd * t))
            } else if abs(zeta - 1) < 0.000001 {
                return target - exp(-omega * t) * (delta + (initialVelocity + omega * delta) * t)
            }
            let wd = omega * sqrt(zeta * zeta - 1), frequency = min(wd * t, 300)
            return target - exp(-zeta * omega * t) * ((initialVelocity + zeta * omega * delta) * sinh(frequency) + wd * delta * cosh(frequency)) / wd
        }
        let next = position(dt)
        velocity = (position(dt + 0.0001) - next) / 0.0001
        if zeta >= 1, (value <= target && next > target) || (value >= target && next < target) { value = target; velocity = 0 }
        else { value = next }
    }
}

/// 贝塞尔反解与缓动映射（AGPL-3.0 移植部分，见文件头的版权声明）。
public enum DemoMotion {
    public static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ time: Double) -> Double {
        let target = max(0, min(1, time))
        if target == 0 || target == 1 { return target }
        func sample(_ a: Double, _ b: Double, _ t: Double) -> Double {
            let u = 1 - t
            return 3 * a * u * u * t + 3 * b * u * t * t + t * t * t
        }
        var t = target
        for _ in 0..<8 {
            let u = 1 - t, delta = sample(x1, x2, t) - target
            let derivative = 3 * x1 * u * u + 6 * (x2 - x1) * u * t + 3 * (1 - x2) * t * t
            if abs(delta) < 0.000001 || abs(derivative) < 0.000001 { break }
            t -= delta / derivative
        }
        var lower = 0.0, upper = 1.0
        t = max(0, min(1, t))
        for _ in 0..<10 {
            let x = sample(x1, x2, t)
            if abs(x - target) < 0.000001 { break }
            if x < target { lower = t } else { upper = t }
            t = (lower + upper) / 2
        }
        return sample(y1, y2, t)
    }
    public static func easeOut(_ time: Double) -> Double { bezier(0.16, 1, 0.3, 1, time) }
}

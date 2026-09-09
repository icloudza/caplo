import Foundation

/// 光标外观：按压区间、形态交叉淡化与提前渐显。
/// 在载入时建立索引，随机定位与导出不依赖上一帧状态；原 MIT 声明随资源分发。
struct PointerAppearance: Sendable {
    struct Press: Sendable { var start: Double; var end: Double }
    struct Shape: Sendable { let time: Double; let previous: PointerShape; let current: PointerShape }
    struct Rest: Sendable { let start: Double; let end: Double }
    let presses: [Press]
    let shapes: [Shape]
    let rests: [Rest]

    init(events: [PointerSample]) {
        var presses: [Press] = [], open: [Int: Int] = [:], shapes: [Shape] = [], rests: [Rest] = []
        var shape: PointerShape = .arrow
        var lastMotion = events.first?.time ?? 0
        var anchor = events.first
        for event in events {
            let button = event.button ?? 0
            if event.kind == .click {
                open[button] = presses.count
                // 无 release 的旧事件采用短点击回退，不能永远停在按压状态。
                presses.append(Press(start: event.time, end: event.time + 0.09))
            } else if event.kind == .release, let index = open.removeValue(forKey: button) {
                presses[index].end = event.time
            } else if event.kind == .exit {
                for index in open.values { presses[index].end = event.time }
                open.removeAll()
            }
            let next = event.shape ?? shape
            if next != shape { shapes.append(Shape(time: event.time, previous: shape, current: next)); shape = next }
            // 相对静止锚点累计位移，缓慢移动不会被逐帧阈值误判为静止。
            let active = anchor == nil || hypot(event.x - (anchor?.x ?? event.x), event.y - (anchor?.y ?? event.y)) > 0.004
                || [.click, .release, .drag, .scroll, .exit].contains(event.kind)
            if active {
                if event.time - lastMotion >= 2.75 { rests.append(Rest(start: lastMotion, end: event.time)) }
                lastMotion = event.time; anchor = event
            }
        }
        if let end = events.last?.time, end - lastMotion >= 2.75 { rests.append(Rest(start: lastMotion, end: .infinity)) }
        // 短命形状去抖：A → B → A 且 B 不到 0.3 秒（扫过按钮、链接边缘时的闪一下），整段按 A 算，形状不再高频闪烁；
        // 真正停在控件上的手形（≥ 0.3 秒）照常显示。
        shapes = Self.removingBlips(shapes)
        // 多个鼠标键重叠按下时合并保持区间，后按的键松开不会提前弹回。
        var merged: [Press] = []
        for press in presses {
            if let last = merged.last, press.start <= last.end {
                merged[merged.count - 1].end = max(last.end, press.end)
            } else { merged.append(press) }
        }
        self.presses = merged; self.shapes = shapes; self.rests = rests
    }

    static func removingBlips(_ shapes: [Shape]) -> [Shape] {
        var result = shapes
        var index = 0
        while index + 1 < result.count {
            let change = result[index], back = result[index + 1]
            if back.current == change.previous, back.time - change.time < 0.3 {
                result.removeSubrange(index...index + 1)
                // 去掉一对后，后一个变化的"之前形状"要接回去掉之前的形状。
                if index < result.count { result[index] = Shape(time: result[index].time, previous: change.previous, current: result[index].current) }
                index = max(0, index - 1)
            } else { index += 1 }
        }
        return result
    }

    private func lastIndex<T>(_ values: [T], at time: Double, key: (T) -> Double) -> Int {
        var low = 0, high = values.count
        while low < high { let mid = (low + high) / 2; if key(values[mid]) <= time { low = mid + 1 } else { high = mid } }
        return low - 1
    }

    func apply(to frame: inout PointerFrame, time: Double, start: Double, end: Double, effects: PointerEffects) {
        let index = lastIndex(presses, at: time) { $0.start }
        if index >= 0 {
            let press = presses[index]
            if press.start >= start {
                let speed = effects.bounceSpeed, holdEnd = min(end, max(press.end, press.start + 0.09 / speed))
                let amount = time <= holdEnd ? SceneEvaluator.smootherstep((time - press.start) * speed / 0.09)
                    : 1 - SceneEvaluator.smootherstep((time - holdEnd) * speed / 0.18)
                frame.scale = 1 - effects.bounce * amount
            }
        }
        do {
            let index = lastIndex(shapes, at: time) { $0.time }
            if index >= 0 {
                let change = shapes[index], duration = min(0.14, end - change.time)
                frame.shape = change.current
                if change.time >= start, duration > 0, time - change.time < duration {
                    frame.previousShape = change.previous
                    frame.shapeMix = SceneEvaluator.smootherstep((time - change.time) / duration)
                }
            }
        }
        // 按住不动仍是有效操作，不能在长按菜单或拖拽等待期间隐藏。
        let held = index >= 0 && presses[index].start <= time && time <= presses[index].end
        if effects.hideIdle && !held {
            let index = lastIndex(rests, at: time) { $0.start }
            if index >= 0 {
                let rest = rests[index], a = max(start, rest.start), b = min(end, rest.end)
                if b - a >= 2.75, time < b {
                    let fadeOut = 1 - SceneEvaluator.smootherstep((time - a - 1.5) / 0.5)
                    let fadeIn = rest.end < end ? SceneEvaluator.smootherstep((time - b + 0.35) / 0.35) : 0
                    frame.opacity = max(fadeOut, fadeIn)
                }
            }
        }
    }
}

import Foundation

/// 一次建立关联素材与屏幕包络范围，避免校验每个聚焦时反复扫描全部片段。
struct FocusCoverage {
    private var timelineByClip: [UUID: ClosedRange<Double>] = [:]
    private var sourceByClip: [UUID: ClosedRange<Double>] = [:]
    private var timelineEnvelope: ClosedRange<Double>?
    private var sourceEnvelope: ClosedRange<Double>?

    init(clips: [VideoClip]) {
        var cursor = 0.0
        // 定格卡段算在它冻结自的那条片段名下：镜头被拉长盖住卡段之后仍然"没跨出原片段"，
        // 否则 normalizeTimelineScope 会把它改成智能跟随、顺手清掉烘焙好的运镜路径。
        var holds: [(UUID, ClosedRange<Double>)] = []
        for clip in clips {
            let start = clip.timelineStart ?? cursor, end = start + clip.duration
            cursor = end
            let sourceEnd = clip.sourceStart + clip.playableDuration
            guard start.isFinite, end.isFinite, start >= 0, end > start,
                  clip.sourceStart.isFinite, sourceEnd.isFinite, clip.sourceStart >= 0, sourceEnd > clip.sourceStart else { continue }
            timelineByClip[clip.id] = start...end
            sourceByClip[clip.id] = clip.sourceStart...sourceEnd
            if let source = clip.holdSource { holds.append((source, start...end)) }
            timelineEnvelope = min(timelineEnvelope?.lowerBound ?? start, start)...max(timelineEnvelope?.upperBound ?? end, end)
            sourceEnvelope = min(sourceEnvelope?.lowerBound ?? clip.sourceStart, clip.sourceStart)...max(sourceEnvelope?.upperBound ?? sourceEnd, sourceEnd)
        }
        for (source, range) in holds {
            guard let existing = timelineByClip[source] else { continue }
            timelineByClip[source] = min(existing.lowerBound, range.lowerBound)...max(existing.upperBound, range.upperBound)
        }
    }

    func bounds(for focus: FocusSegment) -> ClosedRange<Double>? {
        if focus.timelineStart != nil { return timelineEnvelope }
        if let target = focus.targetClipID { return sourceByClip[target] }
        return sourceEnvelope
    }

    func fitsTarget(_ focus: FocusSegment) -> Bool {
        guard let target = focus.targetClipID, let bounds = timelineByClip[target] else { return false }
        return focus.editingStart >= bounds.lowerBound - 0.001 && focus.editingStart + focus.duration <= bounds.upperBound + 0.001
    }

    func contains(_ focus: FocusSegment) -> Bool {
        guard let bounds = bounds(for: focus) else { return false }
        // 旧源镜头可跨越被裁掉的原素材；展开时按每次出现裁剪并保留原动画相位。
        guard focus.timelineStart != nil else { return true }
        return focus.editingStart >= bounds.lowerBound - 0.001 && focus.editingStart + focus.duration <= bounds.upperBound + 0.001
    }
}

extension FocusSegment {
    func validTiming(sourceDuration: Double, editedDuration: Double) -> Bool {
        guard start.isFinite, start >= 0, editingStart.isFinite, editingStart >= 0, duration.isFinite, duration > 0,
              editingStart + duration <= (timelineStart == nil ? sourceDuration : editedDuration) + 0.001 else { return false }
        if let offset = transitionOffset, let length = transitionDuration {
            return timelineStart != nil && offset.isFinite && offset >= 0 && length.isFinite && length > 0 && offset + duration <= length + 0.001
        }
        return transitionOffset == nil && transitionDuration == nil
    }
}

/// 一个源镜头可能在多个剪辑中出现；出现位置单独标识，拖动其中一个不会改动其他副本。
public struct FocusSpan: Sendable, Hashable {
    public let focusID: UUID
    public let clipID: UUID?
    public let start: Double
    public let duration: Double
    public var end: Double { start + duration }
}

extension FocusSegment {
    /// 镜头起点在时间线上移动 `delta` 秒但内部运动不变：关键帧时间反向平移；落到起点之前的关键帧
    /// 只保留最后一个作为新的初始相机。
    mutating func shiftPath(by delta: Double) {
        guard var frames = path, !frames.isEmpty else { return }
        frames = frames.map { var frame = $0; frame.time -= delta; return frame }
        if let lastPassed = frames.lastIndex(where: { $0.time < 0 }) {
            var initial = frames[lastPassed]
            initial.time = 0; initial.move = 0
            frames = [initial] + frames[(lastPassed + 1)...]
        }
        frames = frames.filter { $0.time <= duration + 0.001 }
        if let first = frames.first { x = first.x; y = first.y; scale = first.scale }
        path = frames.count > 1 ? frames : nil
    }

    /// 一旦范围跨出原片段，效果就属于成片时间线。旧镜头默认转为智能跟随，
    /// 显式关闭跟随的固定取景保持不变；以后缩回原范围也不再隐式绑定某个片段。
    mutating func normalizeTimelineScope(using coverage: FocusCoverage) {
        guard timelineStart != nil else { return }
        let crossedTarget = targetClipID != nil && !coverage.fitsTarget(self)
        guard followsTimeline == true || crossedTarget else { return }
        if crossedTarget {
            targetClipID = nil
            if followsTimeline != false { followsTimeline = true }
            transitionOffset = nil; transitionDuration = nil
        }
        // 同片段内开启智能跟随不等于解除关联；媒体裁短保留动画相位，渲染路径则重新编译。
        path = nil; sampledPath = nil
    }
}

extension VideoEdit {
    /// 镜头在成片时间轴上的可见段。与遮罩 / 文字 / 字幕同走 `projectSource`，只是**丢掉冻住的那一截**：
    /// 保持末帧的画面上不该继续推近（那一段本来就没有新内容），这条与遮罩正好相反。
    ///
    /// 索引必须按 `orderedScreenClips` 建、按"真正露出来的段"投影：
    /// 用 `clips` 原序 + `visibleClips` 的老写法在图层工程里既吃不到区间裁剪，
    /// 也会让被上层完全盖住的片段照样投影出一段镜头。
    public func focusSpans(in range: Range<Double>? = nil, using existingIndex: TimelineIndex? = nil) -> [FocusSpan] {
        let index = existingIndex ?? TimelineIndex(clips: orderedScreenClips)
        let visible = range ?? 0..<duration
        var result: [FocusSpan] = []
        for focus in focuses where !focus.automatic || automaticFocus {
            if let start = focus.timelineStart {
                if start < visible.upperBound && start + focus.duration > visible.lowerBound {
                    result.append(FocusSpan(focusID: focus.id, clipID: nil, start: start, duration: focus.duration))
                }
                continue
            }
            for span in index.visibleSpans(in: visible) {
                let clip = index.clips[span.index]
                for piece in Self.projectSource(low: focus.start, high: focus.start + focus.duration, clip: clip,
                                                base: index.boundaries[span.index], spanStart: span.start, spanEnd: span.end)
                where !piece.frozen {
                    guard piece.start < visible.upperBound, piece.start + piece.duration > visible.lowerBound else { continue }
                    result.append(FocusSpan(focusID: focus.id, clipID: clip.id, start: piece.start, duration: piece.duration))
                }
            }
        }
        return result
    }

    /// 首次手动拖动把该源镜头展开为各次出现的编辑时间范围，选中项沿用 ID，其他出现保持原自动状态。
    public mutating func materializeFocus(_ span: FocusSpan) {
        guard let position = focuses.firstIndex(where: { $0.id == span.focusID }), focuses[position].timelineStart == nil else { return }
        let original = focuses[position]
        let appearances = focusSpans().filter { $0.focusID == span.focusID }
        let clipsByID = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        var replacement: [FocusSegment] = []
        for appearance in appearances {
            var copy = original
            copy.id = appearance.clipID == span.clipID ? original.id : UUID()
            copy.targetClipID = clips.contains(where: { $0.timelineStart != nil }) ? appearance.clipID : nil
            copy.timelineStart = appearance.start; copy.duration = appearance.duration
            // 其他出现保留原动画相位；不能因可见范围被剪短就重新播放入场动画。
            if let clipID = appearance.clipID, let clip = clipsByID[clipID] {
                copy.transitionOffset = max(0, clip.sourceStart - original.start)
                copy.transitionDuration = original.duration
            }
            replacement.append(copy)
        }
        focuses.replaceSubrange(position...position, with: replacement)
    }

    public enum FocusDragEdge: Sendable { case body, leading, trailing }

    /// 显式镜头可覆盖成片中的全部录制画面；摄像头和声音不能扩大聚焦范围。
    /// 尚未展开的旧源镜头仍使用原素材时间，不能把源起点与成片起点混算。
    public func focusBounds(for id: UUID) -> ClosedRange<Double>? {
        guard let focus = focuses.first(where: { $0.id == id }) else { return nil }
        return FocusCoverage(clips: clips).bounds(for: focus)
    }

    /// 时间线拖边与属性面板共用时长变更规则；修改前先把被分割镜头的动画偏移展开，
    /// 修改后裁掉范围外的路径，避免面板缩短后留下非法关键帧而在提交时回滚。
    public mutating func dragFocus(id: UUID, edge: FocusDragEdge, delta: Double) {
        let coverage = FocusCoverage(clips: clips)
        guard delta.isFinite, let index = focuses.firstIndex(where: { $0.id == id }),
              let bounds = coverage.bounds(for: focuses[index]) else { return }
        let start = focuses[index].editingStart
        guard start.isFinite, focuses[index].duration.isFinite, focuses[index].duration > 0 else { return }
        if let offset = focuses[index].transitionOffset { focuses[index].shiftPath(by: offset) }
        let length = focuses[index].duration
        let available = bounds.upperBound - bounds.lowerBound
        let minimum = min(1.0 / 30, available, length)
        switch edge {
        case .body:
            focuses[index].duration = min(length, available)
            focuses[index].editingStart = min(bounds.upperBound - focuses[index].duration, max(bounds.lowerBound, start + delta))
        case .leading:
            let end = min(bounds.upperBound, max(bounds.lowerBound + minimum, start + length))
            let next = min(end - minimum, max(bounds.lowerBound, start + delta))
            focuses[index].editingStart = next; focuses[index].duration = end - next
            focuses[index].shiftPath(by: next - start)
        case .trailing:
            let next = min(bounds.upperBound - minimum, max(bounds.lowerBound, start))
            focuses[index].editingStart = next
            focuses[index].duration = min(bounds.upperBound - next, max(minimum, length + delta))
            if next != start { focuses[index].shiftPath(by: next - start) }
        }
        focuses[index].shiftPath(by: 0)
        focuses[index].automatic = false
        focuses[index].transitionOffset = nil; focuses[index].transitionDuration = nil
        focuses[index].normalizeTimelineScope(using: coverage)
    }

    /// 加载旧工程和裁短媒体时，聚焦只保留与录制相交的部分；不平移残段、不撑长成片。
    /// 局部镜头裁剪保留动画相位；跨片段镜头保留完整有效覆盖范围及显式的固定取景选择。
    public mutating func constrainTimelineFocuses() {
        let coverage = FocusCoverage(clips: clips)
        focuses = focuses.compactMap { original in
            guard let bounds = coverage.bounds(for: original) else { return nil }
            guard let start = original.timelineStart else { return original }
            // 真正损坏的数据交由 validate 拒绝，不能把非法数值当成普通越界默默修复。
            guard start.isFinite, start >= 0, original.duration.isFinite, original.duration > 0 else { return original }
            if let offset = original.transitionOffset, let length = original.transitionDuration {
                guard offset.isFinite, offset >= 0, length.isFinite, length > 0,
                      offset + original.duration <= length + 0.001 else { return original }
            }
            let lower = max(start, bounds.lowerBound), upper = min(start + original.duration, bounds.upperBound)
            guard upper > lower else { return nil }
            var copy = original
            if lower != start || upper != start + original.duration {
                copy.timelineStart = lower; copy.duration = upper - lower
                if original.transitionOffset == nil && original.transitionDuration == nil {
                    copy.transitionOffset = lower - start; copy.transitionDuration = original.duration
                } else if let offset = original.transitionOffset, original.transitionDuration != nil {
                    copy.transitionOffset = offset + lower - start
                }
            }
            copy.normalizeTimelineScope(using: coverage)
            return copy
        }
    }
}

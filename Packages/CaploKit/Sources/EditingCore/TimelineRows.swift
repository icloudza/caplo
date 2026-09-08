import Foundation

extension VideoEdit {
    /// 行分组只描述编辑器布局；行内成员仍按 layerOrder 保留合成优先级。
    /// 单次扫描建立成员索引，十万独立块不会对每个块反复遍历所有分组。
    public var timelineRows: [[UUID]] {
        let order = orderedLayerIDs
        guard let rowGroups, !rowGroups.isEmpty else { return order.map { [$0] } }
        let valid = Set(order)
        var membership: [UUID: Int] = [:]
        var grouped: [Int: [UUID]] = [:]
        for (number, group) in rowGroups.enumerated() {
            for id in group where valid.contains(id) && membership[id] == nil { membership[id] = number }
        }
        for id in order {
            if let number = membership[id] { grouped[number, default: []].append(id) }
        }
        var emitted = Set<Int>(), result: [[UUID]] = []
        result.reserveCapacity(order.count)
        for id in order {
            if let number = membership[id], let group = grouped[number], group.count > 1 {
                if emitted.insert(number).inserted { result.append(group) }
            } else { result.append([id]) }
        }
        return result
    }

    /// 清除删除后的悬空成员、重复归属及单例；保存阶段调用可保持工程字段最小化。
    public mutating func normalizeTimelineRows() {
        guard rowGroups != nil else { return }
        let groups = timelineRows.filter { $0.count > 1 }
        rowGroups = groups.isEmpty ? nil : groups
    }

    /// 已有类型共用真实时间范围；旧连续素材的起点按原数组展开，不能用显示宽度判断冲突。
    public var timelineBlockRanges: [UUID: Range<Double>] {
        var result: [UUID: Range<Double>] = [:]
        for values in [clips, cameraClips ?? [], systemClips ?? [], microphoneClips ?? []] {
            var cursor = 0.0
            for clip in values {
                let start = clip.timelineStart ?? cursor, end = start + clip.duration
                if start.isFinite, end.isFinite, start >= 0, end > start { result[clip.id] = start..<end }
                cursor = end
            }
        }
        for focus in focuses {
            let start = focus.editingStart, end = start + focus.duration
            if start.isFinite, end.isFinite, start >= 0, end > start { result[focus.id] = start..<end }
        }
        if focuses.contains(where: { $0.timelineStart == nil }) {
            // 同一个旧源镜头可能在多次剪辑出现，尚未展开时使用包络范围保守拒绝冲突。
            var legacyRanges: [UUID: Range<Double>] = [:]
            let legacy = Set(focuses.filter { $0.timelineStart == nil }.map(\.id))
            for span in focusSpans() where legacy.contains(span.focusID) {
                let previous = legacyRanges[span.focusID]
                legacyRanges[span.focusID] = min(previous?.lowerBound ?? span.start, span.start)..<max(previous?.upperBound ?? span.end, span.end)
            }
            result.merge(legacyRanges) { _, mapped in mapped }
        }
        return result
    }

    public func canPlaceBlock(_ id: UUID, inRowContaining target: UUID) -> Bool {
        let ranges = timelineBlockRanges
        guard let candidate = ranges[id], let row = timelineRows.first(where: { $0.contains(target) }) else { return false }
        return row.allSatisfy { member in
            guard member != id else { return true }
            guard let other = ranges[member] else { return false }
            return !Self.rowRangesOverlap(candidate, other)
        }
    }

    /// 只允许没有时间交叠的块共行；失败时包括原行分组在内的编辑内容完全不变。
    @discardableResult public mutating func placeBlock(_ id: UUID, inRowContaining target: UUID) -> Bool {
        guard canPlaceBlock(id, inRowContaining: target), let row = timelineRows.first(where: { $0.contains(target) }) else { return false }
        if row.contains(id) { normalizeTimelineRows(); return true }
        materializeRowTiming()
        let previous = orderedLayerIDs
        let members = Set(row + [id])
        let merged = previous.filter { members.contains($0) }
        let anchor = previous.firstIndex(of: row[0]) ?? previous.count
        let insertion = previous.prefix(anchor).filter { !members.contains($0) }.count
        var order = previous.filter { !members.contains($0) }
        order.insert(contentsOf: merged, at: insertion)
        var groups = timelineRows.compactMap { group -> [UUID]? in
            let remainder = group.filter { !members.contains($0) }
            return remainder.count > 1 ? remainder : nil
        }
        groups.append(merged)
        layerOrder = order; rowGroups = groups
        normalizeTimelineRows()
        return true
    }

    /// 脱离原同行并插到目标整行上方；nil 表示成为末行。
    public mutating func placeBlock(_ id: UUID, beforeRowContaining target: UUID?) {
        guard id != target, orderedLayerIDs.contains(id) else { return }
        materializeRowTiming()
        moveLayer(id, before: target)
    }

    /// 拖行头时移动整行，不改变行内顺序、时间或源起点。
    public mutating func moveTimelineRow(containing id: UUID, before target: UUID?) {
        let rows = timelineRows
        guard let row = rows.first(where: { $0.contains(id) }), target.map({ !row.contains($0) }) ?? true else { return }
        materializeRowTiming()
        let members = Set(row), order = orderedLayerIDs
        let targetAnchor = target.flatMap { target in rows.first(where: { $0.contains(target) })?.first }
        var remaining = order.filter { !members.contains($0) }
        let insertion = targetAnchor.flatMap { remaining.firstIndex(of: $0) } ?? remaining.count
        remaining.insert(contentsOf: order.filter { members.contains($0) }, at: insertion)
        layerOrder = remaining
        normalizeTimelineRows()
    }

    /// 同行内平移和拖边允许端点相接。录制及其关联聚焦共用位移，避免主块移动后跟随效果撞入另一行的静止块。
    public func rowDragDelta(for id: UUID, edge: FocusDragEdge, proposed: Double, leavingRow: Bool = false) -> Double {
        guard proposed.isFinite else { return 0 }
        guard let rowGroups, !rowGroups.isEmpty else { return proposed }
        let rows = timelineRows
        let ranges = timelineBlockRanges
        if edge == .body {
            var moving: Set<UUID> = [id]
            if clips.contains(where: { $0.id == id }) { moving.formUnion(focuses.filter { $0.targetClipID == id }.map(\.id)) }
            var lower = -Double.infinity, upper = Double.infinity
            for row in rows where row.count > 1 {
                let constrained = row.filter { moving.contains($0) && !(leavingRow && $0 == id) }
                guard !constrained.isEmpty else { continue }
                // 同行的多个跟随聚焦彼此没有相对移动，不能互相成为障碍。
                let stationaryIDs = row.filter { !moving.contains($0) }
                let stationary = stationaryIDs.compactMap { ranges[$0] }.sorted { $0.lowerBound < $1.lowerBound }
                guard stationary.count == stationaryIDs.count else { return 0 }
                var latestEnd = 0.0
                let precedingEnds = stationary.map { range in latestEnd = max(latestEnd, range.upperBound); return latestEnd }
                for member in constrained {
                    guard let own = ranges[member] else { return 0 }
                    // 每行静止块只排序一次，各跟随块二分找左右邻界，避免移动集合与全行两两比较。
                    var lo = 0, hi = stationary.count
                    while lo < hi {
                        let mid = (lo + hi) / 2
                        if stationary[mid].lowerBound < own.lowerBound { lo = mid + 1 } else { hi = mid }
                    }
                    let left = lo > 0 ? precedingEnds[lo - 1] : 0
                    let right = stationary.indices.contains(lo) ? stationary[lo].lowerBound : Double.infinity
                    guard left <= own.lowerBound + 0.000_000_001, right >= own.upperBound - 0.000_000_001 else { return 0 }
                    lower = max(lower, left - own.lowerBound)
                    upper = min(upper, right - own.upperBound)
                }
            }
            guard lower <= upper else { return 0 }
            return min(upper, max(lower, proposed))
        }
        guard let row = rows.first(where: { $0.contains(id) }), row.count > 1 else { return proposed }
        guard let own = ranges[id] else { return 0 }
        var left = 0.0, right = Double.infinity
        for member in row where member != id {
            guard let other = ranges[member] else { return 0 }
            guard !Self.rowRangesOverlap(own, other) else { return 0 }
            if other.upperBound <= own.lowerBound + 0.000_000_001 { left = max(left, other.upperBound) }
            if other.lowerBound >= own.upperBound - 0.000_000_001 { right = min(right, other.lowerBound) }
        }
        switch edge {
        case .body: return min(right - own.upperBound, max(left - own.lowerBound, proposed))
        case .leading: return max(left - own.lowerBound, proposed)
        case .trailing: return min(right - own.upperBound, proposed)
        }
    }

    /// moveLayer、新效果插入共用脱离操作；对无分组旧工程是常数时间空操作。
    mutating func removeTimelineRowMember(_ id: UUID) {
        guard let rowGroups else { return }
        self.rowGroups = rowGroups.compactMap { group in
            let remaining = group.filter { $0 != id }
            return remaining.count > 1 ? remaining : nil
        }
        normalizeTimelineRows()
    }

    private static func rowRangesOverlap(_ first: Range<Double>, _ second: Range<Double>) -> Bool {
        let tolerance = 0.000_000_001
        return first.lowerBound < second.upperBound - tolerance && second.lowerBound < first.upperBound - tolerance
    }

    /// 老工程首次共行前冻结原连续位置，只展开实际存在的媒体，不凭空增加摄像头或音频。
    private mutating func materializeRowTiming() {
        func positioned(_ clips: [VideoClip]) -> [VideoClip] {
            var cursor = 0.0
            return clips.map { clip in
                var copy = clip
                copy.timelineStart = clip.timelineStart ?? cursor
                cursor = (copy.timelineStart ?? 0) + clip.duration
                return copy
            }
        }
        clips = positioned(clips)
        if let cameraClips { self.cameraClips = positioned(cameraClips) }
        if let systemClips { self.systemClips = positioned(systemClips) }
        if let microphoneClips { self.microphoneClips = positioned(microphoneClips) }
        schemaVersion = 6
    }
}

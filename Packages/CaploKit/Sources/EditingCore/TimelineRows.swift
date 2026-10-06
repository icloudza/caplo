import Foundation

/// 自动排行用的小顶堆：堆顶是"最早空出来的那一行"。
private struct RowEndHeap {
    private var items: [(end: Double, row: Int)] = []
    var first: (end: Double, row: Int)? { items.first }
    mutating func insert(_ value: (end: Double, row: Int)) {
        items.append(value)
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child].end < items[parent].end else { break }
            items.swapAt(child, parent); child = parent
        }
    }
    mutating func removeFirst() {
        guard items.count > 1 else { items.removeAll(); return }
        items[0] = items.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1, right = left + 1
            var smallest = parent
            if left < items.count, items[left].end < items[smallest].end { smallest = left }
            if right < items.count, items[right].end < items[smallest].end { smallest = right }
            guard smallest != parent else { break }
            items.swapAt(parent, smallest); parent = smallest
        }
    }
}

extension VideoEdit {
    /// 时间线上块的分类。**只有同类的块会自动并到一行**：录制画面归录制画面，声音归声音，
    /// 镜头、遮罩、文字各自成行。混在一起的一行没法读，也没法整行拖。
    public enum RowKind: Hashable, Sendable {
        case media(TimelineMedia)
        case focus
        case mask
        case text
    }

    /// 每个块属于哪一类。声音轨没有实体化（`systemClips == nil`）时它跟着画面块走、共用同一批 ID，
    /// 这里就只登记画面那一份，与时间线上"一个块"的事实一致。
    public var timelineRowKinds: [UUID: RowKind] {
        var result: [UUID: RowKind] = [:]
        for clip in clips { result[clip.id] = .media(.screen) }
        for clip in cameraClips ?? [] where result[clip.id] == nil { result[clip.id] = .media(.camera) }
        for clip in systemClips ?? [] where result[clip.id] == nil { result[clip.id] = .media(.system) }
        for clip in microphoneClips ?? [] where result[clip.id] == nil { result[clip.id] = .media(.microphone) }
        for focus in focuses where result[focus.id] == nil { result[focus.id] = .focus }
        for mask in maskList where result[mask.id] == nil { result[mask.id] = .mask }
        for value in textList where result[value.id] == nil { result[value.id] = .text }
        return result
    }

    /// 行分组只描述编辑器布局；行内成员仍按 layerOrder 保留合成优先级。
    ///
    /// **默认同级**：同一类、时间又不重叠的块自动并到一行——剪一刀不会把一条轨劈成两行，
    /// 插一块卡片也不会多出一行。`rowGroups` 是用户拖出来的显式行，覆盖自动结果；
    /// 只有一个成员的显式行表示"这一块自己占一行"，正是"从别人那一行拖出来"的意思。
    public var timelineRows: [[UUID]] { timelineRows(using: timelineBlockRanges) }

    /// 同上，但用调用方已经算好的时间范围。拖动时每帧都要排行，范围算一次就够，
    /// 再算一遍等于把全部遮罩 / 文字 / 字幕的投影重跑一次。
    public func timelineRows(using ranges: [UUID: Range<Double>]) -> [[UUID]] {
        let order = orderedLayerIDs
        guard !order.isEmpty else { return [] }
        let valid = Set(order)
        var membership: [UUID: Int] = [:]
        var grouped: [Int: [UUID]] = [:]
        for (number, group) in (rowGroups ?? []).enumerated() {
            for id in group where valid.contains(id) && membership[id] == nil { membership[id] = number }
        }
        for id in order {
            if let number = membership[id] { grouped[number, default: []].append(id) }
        }

        // 自动排行：同类的块按起点做区间划分（经典的"会议室"贪心，用最少的行装下互不重叠的区间）。
        // 用小顶堆挑"最早空出来的那一行"，十万个块也是 O(n log n)；线性扫每一行会退化成 O(n²)。
        let kinds = timelineRowKinds
        var rank: [UUID: Int] = [:]
        rank.reserveCapacity(order.count)
        for (number, id) in order.enumerated() { rank[id] = number }
        var byKind: [RowKind: [(id: UUID, range: Range<Double>)]] = [:]
        var loners: [UUID] = []
        for id in order where membership[id] == nil {
            // 排不出时间范围的块（投影不出任何一段的遮罩之类）保守地自己占一行。
            guard let kind = kinds[id], let range = ranges[id] else { loners.append(id); continue }
            byKind[kind, default: []].append((id, range))
        }
        var autoRows: [[UUID]] = []
        var autoIndex: [UUID: Int] = [:]
        for (_, items) in byKind {
            var heap = RowEndHeap()
            for item in items.sorted(by: { ($0.range.lowerBound, rank[$0.id] ?? 0) < ($1.range.lowerBound, rank[$1.id] ?? 0) }) {
                if let free = heap.first, free.end <= item.range.lowerBound + 0.000_000_001 {
                    heap.removeFirst()
                    autoRows[free.row].append(item.id); autoIndex[item.id] = free.row
                    heap.insert((item.range.upperBound, free.row))
                } else {
                    autoRows.append([item.id]); autoIndex[item.id] = autoRows.count - 1
                    heap.insert((item.range.upperBound, autoRows.count - 1))
                }
            }
        }

        // 行摆在**最下面那个成员**的位置上：一行装下整条轨之后，它该沉到自己最底下那一层去。
        // 按最上面的成员算的话，录制画面那一行会浮到镜头聚焦上面——效果本来是压在画面之上的。
        var emittedExplicit = Set<Int>(), emittedAuto = Set<Int>(), result: [[UUID]] = []
        result.reserveCapacity(order.count)
        for id in order.reversed() {
            if let number = membership[id] {
                if emittedExplicit.insert(number).inserted, let group = grouped[number], !group.isEmpty { result.append(group) }
            } else if let number = autoIndex[id] {
                if emittedAuto.insert(number).inserted { result.append(autoRows[number]) }
            } else {
                result.append([id])
            }
        }
        return result.reversed()
    }

    /// 清除删除后的悬空成员与重复归属。**单成员的行要留着**：默认是同类自动并行，
    /// 一个块单独成组正是"用户把它从那一行拖出来了"的唯一表达，删掉它就会被自动并回去。
    public mutating func normalizeTimelineRows() {
        guard let rowGroups else { return }
        let order = orderedLayerIDs, valid = Set(order)
        var rank: [UUID: Int] = [:]
        for (number, id) in order.enumerated() { rank[id] = number }
        var seen = Set<UUID>()
        let groups = rowGroups.compactMap { group -> [UUID]? in
            let cleaned = group.filter { valid.contains($0) && seen.insert($0).inserted }
            // 成员按层序排好再存，文件里读得出行内次序，也和 timelineRows 吐出来的顺序一致。
            return cleaned.isEmpty ? nil : cleaned.sorted { (rank[$0] ?? 0) < (rank[$1] ?? 0) }
        }
        self.rowGroups = groups.isEmpty ? nil : groups
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
        // 四类投影共用同一个时间轴索引：各自新建一次要重排 layerOrder、重扫全部片段。
        let index = TimelineIndex(clips: orderedScreenClips)
        // 遮罩按它在成片上的实际占用范围；被剪成多段的取包络，保守地拒绝同行冲突。
        for span in maskSpans(using: index) {
            let previous = result[span.maskID]
            result[span.maskID] = min(previous?.lowerBound ?? span.start, span.start)..<max(previous?.upperBound ?? span.end, span.end)
        }
        // 字幕不进 layerOrder（它独占一条固定的轨），但范围表要收它，否则拖动时算不出边界。
        for span in captionSpans(using: index) {
            let previous = result[span.cueID]
            result[span.cueID] = min(previous?.lowerBound ?? span.start, span.start)..<max(previous?.upperBound ?? span.end, span.end)
        }
        for span in textSpans(using: index) {
            let previous = result[span.textID]
            result[span.textID] = min(previous?.lowerBound ?? span.start, span.start)..<max(previous?.upperBound ?? span.end, span.end)
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
        guard let candidate = ranges[id], let row = timelineRows(using: ranges).first(where: { $0.contains(target) }) else { return false }
        return row.allSatisfy { member in
            guard member != id else { return true }
            guard let other = ranges[member] else { return false }
            return !Self.rowRangesOverlap(candidate, other)
        }
    }

    /// 只允许没有时间交叠的块共行；失败时包括原行分组在内的编辑内容完全不变。
    @discardableResult public mutating func placeBlock(_ id: UUID, inRowContaining target: UUID) -> Bool {
        let ranges = timelineBlockRanges
        guard canPlaceBlock(id, inRowContaining: target),
              let row = timelineRows(using: ranges).first(where: { $0.contains(target) }) else { return false }
        if row.contains(id) { normalizeTimelineRows(); return true }
        materializeRowTiming()
        let previous = orderedLayerIDs
        let members = Set(row + [id])
        let merged = previous.filter { members.contains($0) }
        let anchor = previous.firstIndex(of: row[0]) ?? previous.count
        let insertion = previous.prefix(anchor).filter { !members.contains($0) }.count
        var order = previous.filter { !members.contains($0) }
        order.insert(contentsOf: merged, at: insertion)
        // 别的行只摘掉被搬走的成员；剩一个人的显式行也要留着（那是"自己占一行"）。
        // 自动排出来的行不写进 rowGroups——它们本来就是算出来的，写死了反而挡住以后的自动并行。
        let explicit = Set((rowGroups ?? []).flatMap { $0 })
        var groups = (rowGroups ?? []).compactMap { group -> [UUID]? in
            let remainder = group.filter { !members.contains($0) && explicit.contains($0) }
            return remainder.isEmpty ? nil : remainder
        }
        groups.append(merged)
        layerOrder = order; rowGroups = groups
        normalizeTimelineRows()
        return true
    }

    /// 脱离原同行并插到目标整行上方；nil 表示成为末行。
    ///
    /// 默认是"同类自动并行"，所以光挪 layerOrder 不够——不把它钉成单独一行，
    /// 下一次排行又会被同类邻居并回去，用户会觉得"拖出来了又弹回去"。
    public mutating func placeBlock(_ id: UUID, beforeRowContaining target: UUID?) {
        guard id != target, orderedLayerIDs.contains(id) else { return }
        materializeRowTiming()
        moveLayer(id, before: target)
        var groups = (rowGroups ?? []).compactMap { group -> [UUID]? in
            let remainder = group.filter { $0 != id }
            return remainder.isEmpty ? nil : remainder
        }
        groups.append([id])
        rowGroups = groups
        normalizeTimelineRows()
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
        // 自动排出来的行同样算数：默认就是同类并行，只看显式分组的话，
        // 一条轨上的两块会互相穿过去——"同一行不许重叠"这条规则就形同虚设。
        // 范围表算一次，排行也用它：分开算等于把全部遮罩 / 文字 / 字幕的投影跑两遍。
        let ranges = timelineBlockRanges
        let rows = timelineRows(using: ranges)
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
    /// 剩下一个人的行要保留：默认是同类自动并行，单成员的显式行正是"这一块自己占一行"，
    /// 顺手删掉的话，别人一动它就被自动并回去了。
    mutating func removeTimelineRowMember(_ id: UUID) {
        guard let rowGroups else { return }
        self.rowGroups = rowGroups.compactMap { group in
            let remaining = group.filter { $0 != id }
            return remaining.isEmpty ? nil : remaining
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
        normalizeSchemaVersion(layered: true)
    }
}

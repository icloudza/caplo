import Foundation

/// 剪辑变更时建立一次前缀索引；播放头、波形和视口查询以二分查找定位，不逐个遍历所有片段。
public struct TimelineIndex: Sendable {
    public let clips: [VideoClip]
    public let boundaries: [Double]
    public var duration: Double { boundaries.last ?? 0 }
    private let layered: Bool
    private let edges: [Double]
    public let spans: [Span]
    public struct Span: Sendable { public let start: Double; public let end: Double; public let index: Int }
    public init(clips: [VideoClip]) {
        self.clips = clips
        layered = clips.contains { $0.timelineStart != nil }
        var starts: [Double] = [], cursor = 0.0
        for clip in clips { let start = clip.timelineStart ?? cursor; starts.append(start); cursor = start + clip.duration }
        let end = zip(starts, clips).map { $0 + $1.duration }.max() ?? 0
        boundaries = starts + [end]
        edges = Array(Set(starts + zip(starts, clips).map { $0 + $1.duration } + [0])).sorted()
        // 扫描线 + 最小堆：数组靠前的图层覆盖后面的图层，构建 O(n log n)，逐帧二分查询。
        let order = clips.indices.sorted { starts[$0] < starts[$1] }
        var heap: [Int] = [], next = 0, resolved: [Span] = []
        for edge in edges.dropLast() {
            while next < order.count, starts[order[next]] <= edge {
                heap.append(order[next]); var child = heap.count - 1
                while child > 0 { let parent = (child - 1) / 2; if heap[parent] <= heap[child] { break }; heap.swapAt(parent, child); child = parent }
                next += 1
            }
            while let first = heap.first, starts[first] + clips[first].duration <= edge {
                heap.swapAt(0, heap.count - 1); heap.removeLast(); var parent = 0
                while parent * 2 + 1 < heap.count {
                    var child = parent * 2 + 1
                    if child + 1 < heap.count, heap[child + 1] < heap[child] { child += 1 }
                    if heap[parent] <= heap[child] { break }; heap.swapAt(parent, child); parent = child
                }
            }
            if let first = heap.first { resolved.append(Span(start: edge, end: starts[first] + clips[first].duration, index: first)) }
        }
        spans = resolved.enumerated().map { number, span in
            Span(start: span.start, end: min(span.end, resolved.indices.contains(number + 1) ? resolved[number + 1].start : end), index: span.index)
        }
    }
    public func clipIndex(at time: Double) -> Int? {
        guard time.isFinite, time >= 0, time < duration else { return nil }
        var lo = 0, hi = spans.count
        while lo < hi { let mid = (lo + hi) / 2; if spans[mid].start <= time { lo = mid + 1 } else { hi = mid } }
        guard lo > 0, time < spans[lo - 1].end else { return nil }
        return spans[lo - 1].index
    }
    /// 成片时刻对应的源时刻。落在卡片上没有源时刻（卡片不引用素材），返回 nil：镜头、光标、遮罩都不会画上去。
    public func sourceTime(at time: Double) -> Double? {
        if let index = clipIndex(at: time) {
            guard clips[index].card == nil else { return nil }
            return clips[index].sourceStart + min(time - boundaries[index], clips[index].playableDuration - 0.00001)
        }
        if time.isFinite, duration > 0, abs(time - duration) < 0.0001 { return sourceTime(at: duration - 0.00001) }
        return nil
    }
    /// 与给定时间范围相交的**可见段**。`spans` 已经把图层遮挡解析过：
    /// 被上层片段盖住的部分不在里面。二分定位，长工程不逐段扫描。
    ///
    /// 与 `visibleClips(in:)` 的区别很关键：后者只是个粗筛（图层化时直接返回全部下标），
    /// 拿它做投影会让被盖住的素材上的遮罩 / 文字 / 字幕照样画到画面上。
    public func visibleSpans(in range: Range<Double>) -> ArraySlice<Span> {
        guard !spans.isEmpty, range.upperBound > range.lowerBound else { return spans[0..<0] }
        var lo = 0, hi = spans.count
        while lo < hi { let mid = (lo + hi) / 2; if spans[mid].end <= range.lowerBound { lo = mid + 1 } else { hi = mid } }
        let first = lo
        hi = spans.count
        while lo < hi { let mid = (lo + hi) / 2; if spans[mid].start < range.upperBound { lo = mid + 1 } else { hi = mid } }
        return spans[first..<max(first, lo)]
    }

    public func visibleClips(in range: Range<Double>) -> Range<Int> {
        guard !clips.isEmpty, range.upperBound > 0, range.lowerBound < duration else { return 0..<0 }
        if layered { return clips.indices }
        let first = max(0, upperBound(max(0, range.lowerBound)) - 1)
        let last = min(clips.count, lowerBound(range.upperBound))
        return first..<max(first, last)
    }
    /// 返回最靠近指针的拼接边界；吸附距离使用像素换算，缩放后保持相同手感。
    public func snap(_ time: Double, tolerance: Double, extra: [Double] = [], excluding: Set<Int> = []) -> Double? {
        guard time.isFinite, tolerance.isFinite, tolerance >= 0 else { return nil }
        if layered { return (edges + extra).filter { abs($0 - time) <= tolerance }.min { abs($0 - time) < abs($1 - time) } }
        let center = lowerBound(time)
        let candidates = [center - 1, center].filter { boundaries.indices.contains($0) && !excluding.contains($0) }.map { boundaries[$0] }
        return (candidates + extra).filter { $0.isFinite && abs($0 - time) <= tolerance }.min { abs($0 - time) < abs($1 - time) }
    }
    public func insertionIndex(at time: Double) -> Int {
        let index = min(clips.count, lowerBound(time))
        if index > 0, abs(time - boundaries[index - 1]) < abs(boundaries[index] - time) { return index - 1 }
        return index
    }
    private func lowerBound(_ value: Double) -> Int {
        var lo = 0, hi = boundaries.count
        while lo < hi { let mid = (lo + hi) / 2; if boundaries[mid] < value { lo = mid + 1 } else { hi = mid } }
        return lo
    }
    private func upperBound(_ value: Double) -> Int {
        var lo = 0, hi = boundaries.count
        while lo < hi { let mid = (lo + hi) / 2; if boundaries[mid] <= value { lo = mid + 1 } else { hi = mid } }
        return lo
    }
}

public enum TimelineTime {
    public static let framesPerSecond = 30.0
    public static func quantized(_ time: Double) -> Double {
        guard time.isFinite else { return 0 }
        return max(0, (min(1e12, time) * framesPerSecond).rounded() / framesPerSecond)
    }
    public static func code(_ time: Double) -> String {
        let frame = Int(min(1e12, max(0, time.isFinite ? time * framesPerSecond : 0)).rounded())
        return String(format: "%02d:%02d:%02d:%02d", frame / 108_000, frame / 1_800 % 60, frame / 30 % 60, frame % 30)
    }
}

extension VideoEdit {
    /// 时间线始终连续；成组移动保留组选片段的原始顺序，目标下标属于移动前的数组。
    public mutating func moveClips(_ ids: Set<UUID>, before insertion: Int) {
        let boundary = min(clips.count, max(0, insertion))
        let moved = clips.filter { ids.contains($0.id) }
        guard !moved.isEmpty else { return }
        let removedBefore = clips.prefix(boundary).filter { ids.contains($0.id) }.count
        clips.removeAll { ids.contains($0.id) }
        clips.insert(contentsOf: moved, at: boundary - removedBefore)
    }
    @discardableResult public mutating func duplicateClips(_ ids: Set<UUID>) -> Set<UUID> {
        guard let last = clips.lastIndex(where: { ids.contains($0.id) }) else { return [] }
        // 卡片的复制走 `insertCard`（要把后面的内容挪开），这里只复制录制画面。
        let copies = clips.filter { ids.contains($0.id) && $0.card == nil }.map { original in
            var copy = original; copy.id = UUID()
            if let start = original.timelineStart { copy.timelineStart = start + original.duration }
            copy.systemGain = original.systemGain; copy.microphoneGain = original.microphoneGain; copy.cursorHidden = original.cursorHidden
            return copy
        }
        clips.insert(contentsOf: copies, at: last + 1)
        return Set(copies.map(\.id))
    }
}

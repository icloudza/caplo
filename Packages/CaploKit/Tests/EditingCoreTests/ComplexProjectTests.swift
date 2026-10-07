import Foundation
import Testing
@testable import EditingCore

/// 复杂工程的不变量测试。
///
/// 编辑器里每一样东西单独看都有测试，但真正出问题的地方在**它们凑在一起**的时候：
/// 一个工程同时有多段画面、摄像头、两条声音、镜头、遮罩、文字、字幕、卡片、
/// 裁切、分屏版式，然后被剪、被拖、被删、被撤销。
/// 这条测试用一串确定性的操作把这些路径走一遍，每走一步都把全部不变量重查一遍——
/// 任何一条路径破坏了工程结构，都会在它发生的那一步当场被抓住，而不是等到用户导出时才炸。
private struct Invariants {
    let edit: VideoEdit
    let sourceDuration: Double
    let step: String

    func check() throws {
        // 1. 工程本身必须始终合法：保存、播放、导出都要先过这一关。
        do { try edit.validate(sourceDuration: sourceDuration) }
        catch { Issue.record("「\(step)」之后工程判为无效：\(error)"); return }

        // 2. 存下来再读回来必须一模一样。
        let data = try JSONEncoder().encode(edit)
        let restored = try JSONDecoder().decode(VideoEdit.self, from: data)
        #expect(restored == edit, "「\(step)」之后存读不一致")

        // 3. 行布局要不重不漏地盖住每一个块。
        let rows = edit.timelineRows
        let flat = rows.flatMap { $0 }
        #expect(Set(flat).count == flat.count, "「\(step)」之后有块同时出现在两行里")
        #expect(Set(flat) == Set(edit.orderedLayerIDs), "「\(step)」之后行布局漏了或多了块")

        // 4. 同一行里的块不许在时间上重叠——这正是"同行"的定义。
        let ranges = edit.timelineBlockRanges
        for row in rows {
            let spans = row.compactMap { ranges[$0] }.sorted { $0.lowerBound < $1.lowerBound }
            for pair in zip(spans, spans.dropFirst()) {
                #expect(pair.0.upperBound <= pair.1.lowerBound + 0.000_001,
                        "「\(step)」之后同一行里 \(pair.0) 与 \(pair.1) 撞上了")
            }
        }

        // 5. 卡片不引用素材：画面上露出来的是卡片的时候，源域的遮罩、文字、字幕都不在那里，也映射不出源时间。
        //    （别的画面块被拖过来盖住卡片时，那一段露的是那块画面，上面的叠加层照常出现。）
        let visible = TimelineIndex(clips: edit.orderedScreenClips)
        func onCard(_ time: Double) -> Bool { visible.clipIndex(at: time).map { visible.clips[$0].card != nil } ?? false }
        for card in edit.clips where card.card != nil {
            let middle = (card.timelineStart ?? 0) + card.duration / 2
            if onCard(middle) { #expect(edit.sourceTime(at: middle) == nil, "「\(step)」之后卡片上映射出了源时间") }
        }
        #expect(!edit.maskSpans().contains { $0.clipID != nil && onCard($0.start + $0.duration / 2) }, "「\(step)」之后遮罩投影到了卡片上")
        #expect(!edit.textSpans().contains { $0.clipID != nil && onCard($0.start + $0.duration / 2) }, "「\(step)」之后文字投影到了卡片上")
        #expect(!edit.captionSpans().contains { $0.clipID != nil && onCard($0.start + $0.duration / 2) }, "「\(step)」之后字幕投影到了卡片上")

        // 6. 所有投影都落在成片范围内，且时长为正。
        let limit = edit.duration + 0.001
        for span in edit.maskSpans() {
            #expect(span.start >= -0.001 && span.end <= limit && span.duration > 0, "「\(step)」遮罩段越界：\(span.start)…\(span.end)")
        }
        for span in edit.textSpans() {
            #expect(span.start >= -0.001 && span.end <= limit && span.duration > 0, "「\(step)」文字段越界：\(span.start)…\(span.end)")
        }
        for span in edit.captionSpans() {
            #expect(span.start >= -0.001 && span.start < limit, "「\(step)」字幕段越界：\(span.start)")
        }
        for span in edit.focusSpans() {
            #expect(span.start >= -0.001 && span.start + span.duration <= limit, "「\(step)」镜头段越界：\(span.start)")
        }

        // 7. 时间线索引与成片时长自洽。
        // 成片时长取四条轨的最远端，画面轨只能不超过它。
        let index = TimelineIndex(clips: edit.orderedScreenClips)
        if let last = index.spans.last {
            #expect(last.end <= edit.duration + 0.01, "「\(step)」画面排到 \(last.end)，超过了成片时长 \(edit.duration)")
        }
        // 8. 层序不重不漏。
        let order = edit.orderedLayerIDs
        #expect(Set(order).count == order.count, "「\(step)」层序里有重复")
    }
}

/// 一个什么都有的工程：三段画面、摄像头、两条声音、三个镜头、两条遮罩、三段文字、六句字幕。
private func complexProject(sourceDuration: Double = 30) -> VideoEdit {
    var edit = VideoEdit(duration: sourceDuration)
    edit.prepareLayerEditing(camera: true, system: true, microphone: true)
    edit.clips = (0..<3).map { number in
        var clip = VideoClip(sourceStart: Double(number) * 10, duration: 10)
        clip.timelineStart = Double(number) * 10
        return clip
    }
    for role in [TimelineMedia.camera, .system, .microphone] {
        edit.setMediaClips(role, (0..<3).map { number in
            var clip = VideoClip(sourceStart: Double(number) * 10, duration: 10)
            clip.timelineStart = Double(number) * 10
            return clip
        })
    }
    edit.focuses = (0..<3).map { number in
        var focus = FocusSegment(start: 0, duration: 3, x: 0.3 + Double(number) * 0.2, y: 0.5, scale: 1.5 + Double(number) * 0.2)
        focus.timelineStart = Double(number) * 9 + 1
        return focus
    }
    for number in 0..<2 {
        var mask = MaskSegment(start: Double(number) * 12 + 1, duration: 4, x: 0.4, y: 0.5, width: 0.25, height: 0.15,
                               kind: number == 0 ? .sensitive : .highlight)
        mask.positionKeys = (0...3).map { MaskPointKeyframe(time: Double($0), x: 0.2 + Double($0) * 0.15, y: 0.5) }
        edit.addMask(mask)
    }
    for number in 0..<3 {
        var text = TextSegment(start: Double(number) * 9, duration: 4, text: "第 \(number + 1) 段说明")
        text.layout = number == 1 ? .splitRight : .overlay
        text.splitRatio = 0.6
        edit.addText(text)
    }
    edit.captionList = (0..<6).map { number in
        CaptionCue(sourceStart: Double(number) * 5, sourceEnd: Double(number) * 5 + 3.5, text: "第 \(number + 1) 句")
    }
    edit.layout.crop = CropRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
    edit.normalizeTimelineRows()
    edit.normalizeSchemaVersion(layered: true)
    return edit
}

@Test func aComplexProjectSurvivesALongSequenceOfEdits() throws {
    let source = 30.0
    var edit = complexProject(sourceDuration: source)
    let original = edit
    var history = EditHistory()
    var stepNumber = 0

    func step(_ name: String, _ body: (inout VideoEdit) -> Void) throws {
        stepNumber += 1
        let previous = edit
        body(&edit)
        // 与编辑器提交路径一致：约束镜头、整理行、归一化版本。
        edit.constrainTimelineFocuses()
        edit.normalizeTimelineRows()
        edit.normalizeSchemaVersion()
        if edit != previous { history.record(previous) }
        try Invariants(edit: edit, sourceDuration: source, step: "\(stepNumber) \(name)").check()
    }

    try Invariants(edit: edit, sourceDuration: source, step: "0 初始").check()

    // —— 剪辑 ——
    let firstClip = edit.clips[0].id
    try step("在 4 秒切一刀") { _ = $0.splitMedia(.screen, id: firstClip, at: 4) }
    try step("在 12 秒切声音") { edit in
        if let id = edit.mediaClips(.system).first(where: { ($0.timelineStart ?? 0) <= 12 && ($0.timelineStart ?? 0) + $0.duration > 12 })?.id {
            _ = edit.splitMedia(.system, id: id, at: 12)
        }
    }

    // —— 插入卡片 ——
    var cardID: UUID?
    try step("在 15 秒插入卡片") { cardID = $0.insertCard(at: 15, duration: 3) }
    #expect(cardID != nil, "卡片没插进去")
    try step("把卡片拉长到 5 秒") { edit in if let cardID { edit.setCardDuration(id: cardID, duration: 5) } }
    try step("把卡片缩到最短") { edit in if let cardID { edit.setCardDuration(id: cardID, duration: 0.1) } }
    try step("拖卡片右缘") { edit in if let cardID { edit.dragMedia(.screen, id: cardID, edge: .trailing, delta: 0.6, sourceDuration: source) } }

    // —— 拖动各类块 ——
    try step("拖画面块") { edit in
        if let id = edit.clips.last?.id { edit.dragMedia(.screen, id: id, edge: .body, delta: 0.4, sourceDuration: source) }
    }
    try step("拖画面块左缘") { edit in
        if let id = edit.clips.last?.id { edit.dragMedia(.screen, id: id, edge: .leading, delta: 0.3, sourceDuration: source) }
    }
    try step("拖文字块") { edit in
        if let id = edit.textList.first?.id { edit.dragText(id: id, edge: .body, delta: 1.2, sourceDuration: source) }
    }
    try step("拖文字块右缘") { edit in
        if let id = edit.textList.first?.id { edit.dragText(id: id, edge: .trailing, delta: -0.8, sourceDuration: source) }
    }
    try step("拖遮罩") { edit in
        if let id = edit.maskList.first?.id { edit.dragMask(id: id, edge: .body, delta: 0.7, sourceDuration: source) }
    }
    try step("拖字幕") { edit in
        if let id = edit.captionList.first?.id { edit.dragCaption(id: id, edge: .body, delta: 0.5, sourceDuration: source) }
    }
    try step("拖镜头右缘") { edit in
        if let id = edit.focuses.first?.id { edit.dragFocus(id: id, edge: .trailing, delta: 0.6) }
    }

    // —— 行操作 ——
    try step("把摄像头拖进画面那一行") { edit in
        if let camera = edit.cameraClips?.first?.id, let screen = edit.clips.first?.id {
            _ = edit.placeBlock(camera, inRowContaining: screen)
        }
    }
    try step("再把摄像头拖出来单独一行") { edit in
        if let camera = edit.cameraClips?.first?.id, let screen = edit.clips.first?.id {
            edit.placeBlock(camera, beforeRowContaining: screen)
        }
    }
    try step("整行换序") { edit in
        if let first = edit.clips.first?.id, let audio = edit.systemClips?.first?.id {
            edit.moveTimelineRow(containing: first, before: audio)
        }
    }

    // —— 版式与画布 ——
    try step("换成左分屏") { edit in
        if let id = edit.textList.last?.id { edit.updateText(id: id) { $0.layout = .splitLeft; $0.splitRatio = 0.3 } }
    }
    try step("换画布比例") { $0.layout.ratio = .portrait }
    try step("改裁切") { $0.layout.crop = CropRect(x: 0.1, y: 0.0, width: 0.8, height: 1.0) }
    try step("关掉自动聚焦") { $0.automaticFocus = false }

    // —— 删除 ——
    try step("删一条遮罩") { edit in if let id = edit.maskList.first?.id { edit.removeMask(id: id) } }
    try step("删一段文字") { edit in if let id = edit.textList.first?.id { edit.removeText(id: id) } }
    try step("删一句字幕") { edit in if let id = edit.captionList.first?.id { edit.captionList.removeAll { $0.id == id } } }
    try step("删一个镜头") { edit in if let id = edit.focuses.first?.id { edit.focuses.removeAll { $0.id == id } } }
    try step("删掉卡片") { edit in if let cardID { edit.removeCard(id: cardID) } }
    try step("删一段画面") { edit in if let id = edit.clips.last?.id { edit.clips.removeAll { $0.id == id } } }

    // —— 撤销一路回到最初 ——
    var undone = edit
    var count = 0
    while let previous = history.undo(current: undone) {
        undone = previous; count += 1
        try Invariants(edit: undone, sourceDuration: source, step: "撤销 \(count)").check()
    }
    #expect(count > 15, "只撤销了 \(count) 步，操作没被记进历史")
    #expect(undone == original, "一路撤销回去之后和最初的工程不一致")
}

/// 撤销栈不能只按条数封顶：一份快照可能钉着几万个采样运镜关键帧。
@Test func theUndoStackIsCappedByWeightNotJustCount() {
    var heavy = VideoEdit(duration: 10)
    heavy.clips = [VideoClip(sourceStart: 0, duration: 10)]
    var focus = FocusSegment(start: 0, duration: 10, x: 0.5, y: 0.5)
    focus.sampledPath = true
    focus.path = (0..<50_000).map { FocusKeyframe(time: Double($0) / 5000, x: 0.5, y: 0.5, scale: 1.5, move: 0) }
    heavy.focuses = [focus]
    var history = EditHistory()
    for _ in 0..<60 { history.record(heavy) }
    #expect(history.canUndo)
    var count = 0
    var current = heavy
    while let previous = history.undo(current: current) { current = previous; count += 1 }
    // 单份就有五万个关键帧，六十份超过总份量上限：要被削掉一部分，但大工程至少还能撤销 30 步。
    #expect(count < 60, "重快照没有被按份量削掉，留了 \(count) 份")
    #expect(count >= 30, "削得太狠，大工程只剩 \(count) 步撤销")
}

import AVFoundation
import CoreGraphics
import Foundation
import Testing
import EditingCore
@testable import RenderKit

/// 换合成指令时不该重新规划运镜。
///
/// 拖遮罩 / 文字 / 字幕时每移动一次鼠标就换一次合成，而运镜规划要把整条指针轨迹重跑一遍
/// （长录制上是好几毫秒）——可这几样东西一个都不影响运镜。只有片段、层序、镜头本身、
/// 镜头风格和自动开关变了才需要重排。
private func plannedEdit() -> VideoEdit {
    var edit = VideoEdit(duration: 12)
    edit.clips = [VideoClip(sourceStart: 0, duration: 12)]
    var focus = FocusSegment(start: 2, duration: 4, x: 0.4, y: 0.6, scale: 1.8)
    focus.followsTimeline = true
    focus.timelineStart = 2
    edit.focuses = [focus]
    edit.addText(TextSegment(start: 1, duration: 2, text: "标题"))
    return edit
}

private func samples() -> PointerTimeline {
    PointerTimeline(events: (0..<600).map { number in
        let time = Double(number) / 50
        return PointerSample(time: time, x: 0.2 + Double(number % 100) / 200, y: 0.5, kind: number % 97 == 0 ? .click : .move)
    })
}

@Test func changingAnOverlayReusesTheAlreadyPlannedCamera() {
    let pointers = samples()
    let base = plannedEdit()
    let first = SceneInstruction(trackID: 1, edit: base, pointers: pointers)
    #expect(first.edit.focuses.first?.path?.isEmpty == false, "夹具没有真的规划出运镜路径")

    // 只动文字：运镜的输入一个都没变，规划结果必须原样搬过来。
    var changed = base
    if let id = changed.textList.first?.id { changed.updateText(id: id) { $0.text = "改过的标题"; $0.x = 0.3 } }
    let reused = SceneInstruction(trackID: 1, edit: changed, pointers: pointers, reusing: first)
    #expect(!reused.replanned, "只改了文字，却把运镜重新规划了一遍")
    #expect(reused.edit.focuses == first.edit.focuses)
    #expect(reused.edit.textList.first?.text == "改过的标题", "文字的改动没带过去")

    // 动了镜头本身就必须重排。
    var moved = base
    moved.focuses[0].scale = 2.4
    let replanned = SceneInstruction(trackID: 1, edit: moved, pointers: pointers, reusing: first)
    #expect(replanned.replanned, "镜头改了却沿用了旧的运镜路径")
    #expect(replanned.edit.focuses != first.edit.focuses)

    // 剪辑变了同样要重排。
    var cut = base
    cut.clips[0].duration = 6
    let recut = SceneInstruction(trackID: 1, edit: cut, pointers: pointers, reusing: first)
    #expect(recut.plan != first.plan)

    // 没有可复用的前一份时照常规划，结果与第一次一致。
    let fresh = SceneInstruction(trackID: 1, edit: base, pointers: pointers, reusing: nil)
    #expect(fresh.replanned)
    #expect(fresh.edit.focuses == first.edit.focuses, "同样的输入应当规划出同样的结果")
}

/// 复用不能省掉"这次真的换了合成"这件事：文字、遮罩、字幕的改动都要落到新指令上。
@Test func reusingThePlanStillCarriesEveryOverlayChange() {
    let pointers = samples()
    let base = plannedEdit()
    let first = SceneInstruction(trackID: 1, edit: base, pointers: pointers)
    var changed = base
    changed.addMask(MaskSegment(start: 1, duration: 2, x: 0.5, y: 0.5, width: 0.2, height: 0.1))
    changed.captionList = [CaptionCue(sourceStart: 0, sourceEnd: 2, text: "一句话")]
    changed.layout.padding = 12
    let reused = SceneInstruction(trackID: 1, edit: changed, pointers: pointers, reusing: first)
    #expect(reused.edit.maskList.count == 1 && reused.edit.captionList.count == 1)
    #expect(reused.edit.layout.padding == 12)
    #expect(!reused.replanned, "加遮罩 / 字幕 / 改留白都不影响运镜，不该重排")
    #expect(reused.edit.focuses == first.edit.focuses)
}

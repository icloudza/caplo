import Foundation
import Testing
@testable import EditingCore

/// 探针：手动加的「跟随」镜头在 model.edit 里只有静态 x/y/scale，
/// 真正的运镜路径是 `resolvingTimelineFocus` 在构建播放项时才编译出来的。
/// 如果画布上的编辑框用 model.edit 求相机、而画面用渲染副本求相机，两者必然对不上。
@Test func followingFocusHasADifferentCameraBeforeAndAfterResolution() {
    var edit = VideoEdit(duration: 0)
    edit.clips = [VideoClip(sourceStart: 0, duration: 10)]
    var focus = FocusSegment(start: 0, duration: 4, x: 0.5, y: 0.5, scale: 1.8)
    focus.timelineStart = 3
    focus.followsTimeline = true
    focus.easeIn = 0.4; focus.easeOut = 0.4
    edit.focuses = [focus]

    // 指针从左走到右：规划器会让相机跟着走。
    let samples: [PointerSample] = (0..<200).map { step in
        let time = Double(step) / 20
        return PointerSample(time: time, x: min(0.95, 0.05 + time * 0.12), y: 0.5, kind: .move)
    }
    let resolved = edit.resolvingTimelineFocus(events: samples)
    #expect(resolved.focuses[0].path != nil, "渲染副本里应当已经编译出运镜路径")

    // 同一时刻，两份数据算出来的相机不一样——差多少就是画布上编辑框偏多少。
    var worst = 0.0
    for step in 0...40 {
        let time = 3 + Double(step) / 10
        let plain = SceneEvaluator.focus(edit: edit, time: time)
        let real = SceneEvaluator.focus(edit: resolved, time: time)
        worst = max(worst, max(abs(plain.targetX - real.targetX), abs(plain.targetY - real.targetY)))
    }
    #expect(worst > 0.05, "两份数据算出的相机只差 \(worst)，这个探针没有意义")
}

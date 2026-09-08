import Testing
import ImageIO
import CoreGraphics
import Foundation
@testable import EditingCore

@Test func pointerInterpolationExitAndMissingSamplesRespectVisibility() {
    let timeline = TimelineIndex(clips: [VideoClip(sourceStart: 0, duration: 2)])
    let events = [PointerSample(time: 0, x: 0.2, y: 0.4, kind: .move), PointerSample(time: 0.1, x: 0.4, y: 0.6, kind: .move),
                  PointerSample(time: 0.12, x: 0.4, y: 0.6, kind: .exit), PointerSample(time: 1, x: 0.8, y: 0.2, kind: .move)]
    let pointer = PointerTimeline(events: events, cursorEmbedded: false)
    let middle = pointer.frame(at: 0.05, timeline: timeline, effects: PointerEffects()).position
    #expect(abs((middle?.x ?? 0) - 0.3) < 0.001)
    #expect(abs((middle?.y ?? 0) - 0.5) < 0.001)
    #expect(pointer.frame(at: 0.13, timeline: timeline, effects: PointerEffects()).position == nil)
    #expect(pointer.frame(at: 1.16, timeline: timeline, effects: PointerEffects()).position == nil)
    #expect(PointerTimeline(events: events).frame(at: 0.05, timeline: timeline, effects: PointerEffects()).position == nil)
    var hidden = PointerEffects(); hidden.cursorVisible = false
    #expect(pointer.frame(at: 0.05, timeline: timeline, effects: hidden).position == nil)
}

@Test func clickEffectsRespectCutsRepeatsAndBoundedWork() throws {
    let clicks = [PointerSample(time: 0.2, x: 0.3, y: 0.4, kind: .click), PointerSample(time: 0.6, x: 0.7, y: 0.8, kind: .click)]
    let pointer = PointerTimeline(events: clicks)
    let timeline = TimelineIndex(clips: [VideoClip(sourceStart: 0.4, duration: 0.5), VideoClip(sourceStart: 0, duration: 0.4), VideoClip(sourceStart: 0.4, duration: 0.5)])
    #expect(pointer.frame(at: 0, timeline: timeline, effects: PointerEffects()).clicks.isEmpty)
    #expect(pointer.frame(at: 0.3, timeline: timeline, effects: PointerEffects()).clicks.first?.position.x == 0.7)
    #expect(pointer.frame(at: 0.8, timeline: timeline, effects: PointerEffects()).clicks.first?.position.x == 0.3)
    #expect(pointer.frame(at: 1.2, timeline: timeline, effects: PointerEffects()).clicks.first?.position.x == 0.7)
    let dense = PointerTimeline(events: (0..<100_000).map { PointerSample(time: Double($0) / 100_000, x: 0.5, y: 0.5, kind: .click) })
    #expect(dense.frame(at: 0.999, timeline: TimelineIndex(clips: [VideoClip(sourceStart: 0, duration: 2)]), effects: PointerEffects()).clicks.count == 16)
    var edit = VideoEdit(duration: 2); edit.pointer = PointerEffects(); edit.pointer?.cursorScale = .infinity
    #expect(throws: EditError.self) { try edit.validate(sourceDuration: 2) }
}

@Test func upstreamPointerSettingsDecodeLegacyAndRoundTrip() throws {
    let old = Data(#"{"cursorVisible":true,"cursorScale":2,"clicksVisible":true,"clickScale":1,"tint":"blue"}"#.utf8)
    let legacy = try JSONDecoder().decode(PointerEffects.self, from: old)
    #expect(legacy.style == .original && legacy.smoothing == 0 && !legacy.loop)
    var effects = legacy
    effects.style = .tahoe; effects.smoothing = 0.8; effects.bounce = 0.3
    effects.sway = 0.5; effects.motionBlur = 0.6; effects.hideIdle = true; effects.loop = true; effects.clickEffect = .echo
    #expect(try JSONDecoder().decode(PointerEffects.self, from: JSONEncoder().encode(effects)) == effects)
    var sample = PointerSample(time: 1, x: 0.3, y: 0.4, kind: .drag)
    sample.button = 1; sample.shape = .grabbing; sample.scrollY = 2
    #expect(try JSONDecoder().decode(PointerSample.self, from: JSONEncoder().encode(sample)) == sample)
}

@Test func upstreamMotionIsSeekIndependentAndClicksStayOnTarget() {
    var samples = (0...240).map { PointerSample(time: Double($0) / 120, x: Double($0) / 300 + 0.05, y: 0.4, kind: .move) }
    samples.append(PointerSample(time: 1, x: 0.45, y: 0.4, kind: .click))
    let pointers = PointerTimeline(events: samples, cursorEmbedded: false)
    let timeline = TimelineIndex(clips: [VideoClip(sourceStart: 0, duration: 2)])
    var effects = PointerEffects(); effects.smoothing = 0.8; effects.bounce = 0.3; effects.sway = 0.6; effects.motionBlur = 1
    let a = pointers.frame(at: 0.8, timeline: timeline, effects: effects)
    _ = pointers.frame(at: 1.7, timeline: timeline, effects: effects)
    let b = pointers.frame(at: 0.8, timeline: timeline, effects: effects)
    #expect(a.position == b.position && a.rotation == b.rotation && a.trail == b.trail)
    #expect((a.position?.x ?? 1) < 0.37 && a.trail.count <= 5)
    #expect(pointers.frame(at: 1, timeline: timeline, effects: effects).position?.x == 0.45)
    #expect(pointers.frame(at: 1.09, timeline: timeline, effects: effects).scale < 0.8)
    let cut = TimelineIndex(clips: [VideoClip(sourceStart: 1.4, duration: 0.5)])
    let first = pointers.frame(at: 0, timeline: cut, effects: effects)
    #expect(first.trail.isEmpty && first.clicks.isEmpty && first.scale == 1)
    #expect(abs((first.position?.x ?? 0) - 0.61) < 0.00001)
}

@Test func idleFadeLoopAndExitHaveExplicitBoundaries() {
    let events = (0...240).map { PointerSample(time: Double($0) / 60, x: 0.3, y: 0.4, kind: .move) }
    let pointer = PointerTimeline(events: events, cursorEmbedded: false)
    let timeline = TimelineIndex(clips: [VideoClip(sourceStart: 0, duration: 4)])
    var effects = PointerEffects(); effects.hideIdle = true
    #expect(pointer.frame(at: 2, timeline: timeline, effects: effects).opacity == 0)
    effects.loop = true
    #expect(pointer.frame(at: 3.9, timeline: timeline, effects: effects).opacity == 1)
    let exited = PointerTimeline(events: events + [PointerSample(time: 3.95, x: 0.3, y: 0.4, kind: .exit)], cursorEmbedded: false)
    #expect(exited.frame(at: 3.96, timeline: timeline, effects: effects).position == nil)
}

@Test func bezierAndEditableFollowStayBounded() {
    #expect(DemoMotion.easeOut(0) == 0 && DemoMotion.easeOut(1) == 1)
    #expect(DemoMotion.easeOut(0.5) > 0.9)
    let values = (0...100).map { DemoMotion.easeOut(Double($0) / 100) }
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    let segment = FocusSegment(start: 0, duration: 4, x: 0.3, y: 0.5)
    let events = (0..<240).map { PointerSample(time: Double($0) / 60, x: $0 < 60 ? 0.3 : 0.9, y: 0.5, kind: .move) }
    let follow = AutoFocus.following(segment, events: events, style: AutoFocusStyle())
    #expect((follow.path?.count ?? 0) > 1)
    #expect(follow.camera(at: 3).x > 0.5)
    var edit = VideoEdit(duration: 4); var demo = segment; demo.easing = .demo; edit.focuses = [demo]
    #expect(SceneEvaluator.focus(edit: edit, time: 0).scale == 1)
    #expect(SceneEvaluator.focus(edit: edit, time: 3.999).scale < 1.001)
}

@Test func longPointerTrackHasBoundedFrameCost() throws {
    let events = (0..<108_000).map { index in
        let time = Double(index) / 60
        return PointerSample(time: time, x: 0.5 + sin(time * 2) * 0.4, y: 0.5 + cos(time) * 0.3, kind: index % 120 == 0 ? .click : .move)
    }
    let pointer = PointerTimeline(events: events, cursorEmbedded: false)
    let timeline = TimelineIndex(clips: [VideoClip(sourceStart: 0, duration: 1800)])
    var effects = PointerEffects(); effects.smoothing = 0.8; effects.motionBlur = 1; effects.sway = 1; effects.bounce = 0.3
    var durations: [Double] = []
    for i in 0..<240 {
        let start = Date.timeIntervalSinceReferenceDate
        let frame = pointer.frame(at: 1700 + Double(i) / 60, timeline: timeline, effects: effects)
        durations.append((Date.timeIntervalSinceReferenceDate - start) * 1000)
        #expect(frame.position?.x.isFinite == true && frame.trail.count <= 5)
    }
    durations.sort()
    print("光标性能：108000 事件，240 帧，P50=\(durations[120])ms，P95=\(durations[228])ms，最大=\(durations.last!)ms")
    // 保留宽松回归上限；正式实时预算以 Release 基准和真实 4K 合成验收为准。
    #expect(durations[228] < 50)
}

/// 光标角度与动态朝向：角度直接加到旋转上；朝向按移动方向与箭头默认朝向的夹角转，向左上移动时几乎不转，向右移动转约 117°。
@Test func cursorAngleAndDirectionFollowRotateTheFrame() throws {
    var effects = PointerEffects.recommended
    effects.smoothing = 0; effects.sway = 0
    let data = try JSONEncoder().encode(effects)
    let decoded = try JSONDecoder().decode(PointerEffects.self, from: data)
    #expect(decoded.angle == 0 && decoded.directionFollow == 0 && decoded.isValid)
    effects.angle = 200; #expect(!effects.isValid)
    effects.angle = 90
    let samples = [PointerSample(time: 0, x: 0.2, y: 0.5, kind: .move), PointerSample(time: 0.1, x: 0.5, y: 0.5, kind: .move), PointerSample(time: 0.2, x: 0.8, y: 0.5, kind: .move)]
    let timeline = PointerTimeline(events: samples, cursorEmbedded: false)
    let index = TimelineIndex(clips: [VideoClip(sourceStart: 0, duration: 1)])
    let still = timeline.frame(at: 0.15, timeline: index, effects: effects)
    #expect(abs(still.rotation - .pi / 2) < 1e-6)
    effects.angle = 0; effects.directionFollow = 1
    let right = timeline.frame(at: 0.15, timeline: index, effects: effects)
    #expect(abs(right.rotation - (0 - PointerEffects.arrowTipHeading)) < 1e-6)
    let diagonal = [PointerSample(time: 0, x: 0.8, y: 0.9, kind: .move), PointerSample(time: 0.1, x: 0.65, y: 0.6, kind: .move), PointerSample(time: 0.2, x: 0.5, y: 0.3, kind: .move)]
    let upLeft = PointerTimeline(events: diagonal, cursorEmbedded: false).frame(at: 0.15, timeline: index, effects: effects)
    #expect(abs(upLeft.rotation) < 0.05)
    effects.directionFollow = 0.5
    let half = timeline.frame(at: 0.15, timeline: index, effects: effects)
    #expect(abs(half.rotation - right.rotation / 2) < 1e-6)
}

/// 真实光标随帧给出，不再只在"真实光标"样式下才有：样式只换箭头，其他形状按录制时的光标画。
@Test func capturedCursorIsProvidedForEveryStyle() {
    let cursor = CapturedCursor(png: Data(), width: 32, height: 32, hotspotX: 10, hotspotY: 2, scale: 2)
    // 位置插值只认 0.15 秒内的相邻样本，样本按 0.1 秒给。
    let samples = (0...10).map { step -> PointerSample in
        var sample = PointerSample(time: Double(step) / 10, x: 0.5, y: 0.5, kind: .move)
        sample.cursorAssetID = "hand"; sample.shape = .pointer
        return sample
    }
    let timeline = PointerTimeline(events: samples, cursorEmbedded: false, capturedCursors: ["hand": cursor])
    let index = TimelineIndex(clips: [VideoClip(sourceStart: 0, duration: 1)])
    for style in [PointerEffects.Style.tahoe, .macos, .minimal, .captured] {
        var effects = PointerEffects.recommended; effects.style = style
        let frame = timeline.frame(at: 0.45, timeline: index, effects: effects)
        #expect(frame.capturedCursor?.width == 32 && frame.shape == .pointer)
    }
}

/// 自定义光标样式 id 随工程保存，缺省为空；旧文件解码后不受影响。
@Test func customCursorStyleRoundTripsAndDefaultsToNil() throws {
    var effects = PointerEffects.recommended
    #expect(effects.cursorStyle == nil)
    effects.cursorStyle = "1-03"
    let decoded = try JSONDecoder().decode(PointerEffects.self, from: try JSONEncoder().encode(effects))
    #expect(decoded.cursorStyle == "1-03" && decoded.isValid)
    let legacy = try JSONDecoder().decode(PointerEffects.self, from: Data("{\"style\":\"tahoe\"}".utf8))
    #expect(legacy.cursorStyle == nil && legacy.style == .tahoe)
}

/// 光标大小下限 = 系统光标大小：按录制时真实箭头的点高度除以主题光标的 32 点；小于 1 的倍率合法。
@Test func systemCursorScaleComesFromTheCapturedArrow() throws {
    // 64×64 像素、2× 的光标图，箭头只占第 4…49 行（46 像素 = 23 点）：按可见高度算，不按整图的 32 点算。
    let cursor = CapturedCursor(png: try #require(arrowPNG(size: 64, top: 4, bottom: 49)), width: 64, height: 64, hotspotX: 4, hotspotY: 2, scale: 2)
    #expect(abs((cursor.visibleHeightPoints ?? 0) - 23) < 1e-9)
    var sample = PointerSample(time: 0, x: 0.5, y: 0.5, kind: .move); sample.cursorAssetID = "arrow"
    let timeline = PointerTimeline(events: [sample], cursorEmbedded: false, capturedCursors: ["arrow": cursor])
    #expect(abs((timeline.systemCursorScale ?? 0) - 23.0 / 32) < 1e-9)
    #expect(CapturedCursor(png: Data(), width: 8, height: 8, hotspotX: 0, hotspotY: 0, scale: 1).visibleHeightPoints == nil)
    #expect(PointerTimeline(events: [sample], cursorEmbedded: false).systemCursorScale == nil)
    var effects = PointerEffects.recommended
    effects.cursorScale = 0.72; #expect(effects.isValid)
    effects.cursorScale = 0.1; #expect(!effects.isValid)
}

/// 生成一张只有第 top…bottom 行有像素的方形 PNG。
private func arrowPNG(size: Int, top: Int, bottom: Int) -> Data? {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    // CGContext 的 y 向上：第 top…bottom 行（从上数）对应 y = size - bottom - 1 … size - top - 1。
    context.fill(CGRect(x: 6, y: size - bottom - 1, width: 12, height: bottom - top + 1))
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

/// "显示光标"开关已去掉：旧文件里存过 false 也恢复显示，点击高亮的保存值不受影响。
@Test func savedHiddenCursorIsIgnoredSinceTheToggleIsGone() throws {
    let effects = try JSONDecoder().decode(PointerEffects.self, from: Data(#"{"cursorVisible":false,"clicksVisible":false}"#.utf8))
    #expect(effects.cursorVisible && !effects.clicksVisible)
}


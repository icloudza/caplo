import AppKit
import EditingCore
import ProjectKit
import Testing
@testable import Features

extension WindowLifecycleTests {
    /// 把时间线视口渲染成 PNG，肉眼核对行布局。只在设了 CAPLO_SHOT 时跑。
    @Test func timelineScreenshotForReview() async throws {
        guard let out = ProcessInfo.processInfo.environment["CAPLO_SHOT"] else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        let url = try await makeEditorFixture(root: root, audio: true)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        defer { model.close() }
        await model.open()
        for _ in 0..<300 where model.loading { try await Task.sleep(for: .milliseconds(10)) }

        var edit = model.edit
        edit.prepareLayerEditing(camera: false, system: true, microphone: true)
        let piece = 3.5
        edit.clips = (0..<3).map { number in
            var clip = VideoClip(sourceStart: 0, duration: piece); clip.timelineStart = Double(number) * piece; return clip
        }
        for role in [TimelineMedia.system, .microphone] {
            edit.setMediaClips(role, (0..<2).map { number in
                var clip = VideoClip(sourceStart: 0, duration: piece)
                clip.timelineStart = Double(number) * piece * 1.5; return clip
            })
        }
        edit.focuses = (0..<2).map { number in
            var focus = FocusSegment(start: 0, duration: 2, x: 0.4, y: 0.6, scale: 1.8)
            focus.timelineStart = Double(number) * 5 + 0.5; return focus
        }
        for number in 0..<2 {
            var mask = MaskSegment(start: 0, duration: 1.6, x: 0.4, y: 0.5, width: 0.2, height: 0.1,
                                   kind: number == 0 ? .sensitive : .highlight)
            mask.timelineStart = Double(number) * 4 + 1
            edit.addMask(mask)
        }
        for (number, body) in ["标题", "打字机", "副标题"].enumerated() {
            var text = TextSegment(start: 0, duration: 2, text: body)
            text.timelineStart = Double(number) * 3.4 + 0.2
            edit.addText(text)
        }
        edit.captionList = (0..<5).map { number in
            var cue = CaptionCue(sourceStart: 0, sourceEnd: 1.2, text: "第 \(number + 1) 句")
            cue.timelineStart = Double(number) * 2; return cue
        }
        model.commit { $0 = edit }
        _ = model.edit.insertHoldCard(at: 5.2, duration: 1.5, sourceDuration: model.entry.document.duration, text: "第二章")
        model.commit { _ in }
        for _ in 0..<200 where model.rebuilding { try await Task.sleep(for: .milliseconds(10)) }

        let viewport = TimelineViewport(); viewport.zoom = 1.2
        let view = TimelineViewportView(model: model, viewport: viewport)
        view.frame = CGRect(x: 0, y: 0, width: 1240, height: 330)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        window.appearance = NSAppearance(named: .darkAqua)
        defer { view.detach(); window.contentView = nil; window.close() }
        view.update(edit: model.edit, analysis: model.analysis, selection: model.selectedClipIDs,
                    primary: model.selectedClip, focus: model.selectedFocus, mask: nil, text: nil, caption: nil,
                    zoom: viewport.zoom, fit: 1)
        view.displayIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out))
        print("行数 \(model.edit.timelineRows.count)：", model.edit.timelineRows.map(\.count))
        print("错误", model.error ?? "无", "画面", model.edit.clips.count, "文字", model.edit.textList.count, "遮罩", model.edit.maskList.count, "字幕", model.edit.captionList.count, "镜头", model.edit.focuses.count, "声音", model.edit.mediaClips(.system).count)
    }
}

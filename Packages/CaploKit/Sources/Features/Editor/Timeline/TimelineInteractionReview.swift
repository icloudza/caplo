import AppKit
import QuartzCore
import ProjectKit
import EditingCore

/// 仅由 PreviewGallery 调用：渲染本进程的时间线与拖动图层，不读取桌面或控制其他应用。
@MainActor
public enum TimelineInteractionReview {
    public static func render(projectURL: URL, output: URL, sharedRows: Bool = false) async throws {
        let document = try ProjectStorage.load(projectURL)
        let model = VideoEditorModel(entry: LibraryEntry(url: projectURL, document: document))
        await model.open()
        defer { model.close() }
        guard model.ready else { throw ReviewError.notReady }
        for _ in 0..<200 {
            if !model.loading && !model.rebuilding { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        if sharedRows, model.edit.clips.count >= 2 {
            let clips = model.edit.clips.sorted { ($0.timelineStart ?? 0) < ($1.timelineStart ?? 0) }
            model.commit { edit in _ = edit.placeBlock(clips[1].id, inRowContaining: clips[0].id) }
        }
        let viewport = TimelineViewport(); viewport.zoom = 1; viewport.fitRequest = 1
        let view = TimelineViewportView(model: model, viewport: viewport)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { view.detach(); window.contentView = nil; window.close() }
        func sync() {
            view.update(edit: model.edit, analysis: model.analysis, selection: model.selectedClipIDs, primary: model.selectedClip,
                        focus: model.selectedFocus, zoom: viewport.zoom, fit: viewport.fitRequest)
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws {
            guard let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { throw ReviewError.notReady }
            switch type { case .leftMouseDown: view.mouseDown(with: event); case .leftMouseDragged: view.mouseDragged(with: event); case .mouseMoved: view.mouseMoved(with: event); default: view.mouseUp(with: event) }
        }
        func save(_ name: String) throws {
            sync(); CATransaction.flush()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ReviewError.notReady }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ReviewError.notReady }
            try data.write(to: output.appendingPathComponent(name + ".png"))
        }
        model.seek(2); sync()
        for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(60))
            sync()
            try mouse(.mouseMoved, CGPoint(x: TimelineViewportView.timeOrigin + 5.5 * 120, y: 18))
            try await Task.sleep(for: .milliseconds(80))
            try save((sharedRows ? "timeline-shared-" : "timeline-skimmer-") + scheme)
            try mouse(.leftMouseDown, CGPoint(x: 32, y: 48))
            try mouse(.leftMouseDragged, CGPoint(x: 160, y: 154))
            sync()
            try save("timeline-drag-" + scheme)
            model.cancelInteraction()
            guard let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                               context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53) else { throw ReviewError.notReady }
            view.keyDown(with: escape)
            sync()
        }
        viewport.zoom = -5; viewport.fitRequest += 1; sync()
        try save("timeline-minimum-blocks")
    }
    private enum ReviewError: Error { case notReady }
}

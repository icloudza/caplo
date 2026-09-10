import AppKit
import SwiftUI
import Testing
import ProjectKit
import EditingCore
@testable import Features

/// 用真实鼠标事件在真实编辑器里拖一次：抓画出来的角把手，改的必须是字号，不能变成"把整段文字挪走"。
extension WindowLifecycleTests {
    @Test(arguments: [("大字", "产品演示", 96.0), ("小字", "小", 30.0)])
    func draggingATextHandleResizesInsteadOfMoving(label: String, body: String, size: Double) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        defer { model.close() }
        await model.open()
        for _ in 0..<300 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        var edit = model.edit
        var text = TextSegment(start: 0, duration: 3, text: body)
        text.timelineStart = 0.2; text.size = size
        edit.addText(text)
        model.commit { $0 = edit }
        let id = try #require(model.edit.textList.first?.id)
        model.selectedText = id
        model.seek(1)

        let view = NSHostingView(rootView: VideoEditorView(model: model, initialTab: "文字") {}
            .frame(width: 1240, height: 900))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1240, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<150 { try await Task.sleep(for: .milliseconds(10)) }
        view.layoutSubtreeIfNeeded()
        let canvas = try #require(allViews(view).compactMap { $0 as? TextCanvasView }.first)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func grip(_ place: (CGRect) -> CGPoint) throws -> CGPoint {
            let ring = TextCanvasMath.handleFrame(try #require(canvas.textFrameForTesting(id)))
            return canvas.convert(place(ring), to: nil)
        }

        // 右下角：字号变大，位置不动。
        let corner = try grip { CGPoint(x: $0.maxX, y: $0.minY) }
        canvas.mouseDown(with: event(.leftMouseDown, corner))
        canvas.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: corner.x + 40, y: corner.y - 25)))
        canvas.mouseUp(with: event(.leftMouseUp, CGPoint(x: corner.x + 40, y: corner.y - 25)))
        let resized = try #require(model.edit.text(id: id))
        #expect(resized.size > size * 1.1, "[\(label)] 拉右下角没有改字号：\(size) → \(resized.size)")
        #expect(resized.x == 0.5 && resized.y == 0.5, "[\(label)] 拉右下角把文字挪走了：(\(resized.x), \(resized.y))")
    }

    private func allViews(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + allViews($0) } }
}

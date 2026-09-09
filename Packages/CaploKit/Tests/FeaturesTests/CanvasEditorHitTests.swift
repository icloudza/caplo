import AppKit
import SwiftUI
import Testing
import EditingCore
import ProjectKit
import RenderKit
@testable import Features

/// 画布上的遮罩 / 文字编辑层夹在成片显示面与空态提示浮层之间。
/// 提示浮层是 SwiftUI 的 `NSHostingView`，靠 `allowsHitTesting(false)` 放行；
/// 一旦它开始吞掉点击，画布上就再也拖不动遮罩和文字了，而且从画面上完全看不出来。
/// 所以这里走真实的视图层级做命中测试，不是直接调编辑层的方法。
extension WindowLifecycleTests {
    @MainActor
    private func makeWorkspace(root: URL) async throws -> (workspace: EditorWorkspaceView, model: VideoEditorModel, window: NSWindow) {
        _ = NSApplication.shared
        let url = try await makeEditorFixture(root: root)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        let viewport = TimelineViewport()
        let workspace = EditorWorkspaceView(model: model, viewport: viewport, addFocus: {})
        workspace.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: workspace.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = workspace
        window.orderFront(nil)
        await model.open()
        for _ in 0..<300 {
            if model.ready, !model.loading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        workspace.layoutSubtreeIfNeeded()
        return (workspace, model, window)
    }

    @Test func clicksReachTheMaskEditorThroughTheOverlay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (workspace, model, window) = try await makeWorkspace(root: root)
        defer { model.close(); window.contentView = nil; window.close() }

        model.seek(1)
        let id = try #require(model.addMask())
        model.maskEditing = true
        model.selectedMask = id
        workspace.layoutSubtreeIfNeeded()

        // 遮罩默认在画面正中；用成片显示面的中心作为落点。
        let canvas = try #require(findCanvasSurface(in: workspace))
        #expect(canvas.videoRect.width > 1 && canvas.videoRect.height > 1, "画面区域是 \(canvas.videoRect)，布局没起来")
        let center = canvas.convert(CGPoint(x: canvas.videoRect.midX, y: canvas.videoRect.midY), to: nil)
        let hit = workspace.hitTest(center)
        #expect(hit is MaskCanvasView, "画面中心的点击落到了 \(type(of: hit ?? workspace))，遮罩拖不动了")

        // 遮罩之外的点击必须放行，不能让编辑层把整块画布吃掉。
        let corner = canvas.convert(CGPoint(x: canvas.videoRect.minX + 3, y: canvas.videoRect.minY + 3), to: nil)
        #expect(!(workspace.hitTest(corner) is MaskCanvasView), "遮罩之外的点击也被编辑层接走了")

        // 不在遮罩面板时整层放行。
        model.maskEditing = false
        #expect(!(workspace.hitTest(center) is MaskCanvasView), "离开遮罩面板后编辑层还在吃点击")
    }

    @Test func clicksReachTheTextEditorThroughTheOverlay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (workspace, model, window) = try await makeWorkspace(root: root)
        defer { model.close(); window.contentView = nil; window.close() }

        model.seek(1)
        var created: UUID?
        model.commit { edit in
            var label = TextPreset.title.segment(start: 0, duration: 4)
            label.text = "标题"; label.enterKind = .none; label.exitKind = .none
            edit.addText(label); created = label.id
        }
        let id = try #require(created)
        model.textEditing = true
        model.selectedText = id
        workspace.layoutSubtreeIfNeeded()

        let canvas = try #require(findCanvasSurface(in: workspace))
        #expect(canvas.videoRect.width > 1 && canvas.videoRect.height > 1, "画面区域是 \(canvas.videoRect)，布局没起来")
        let center = canvas.convert(CGPoint(x: canvas.videoRect.midX, y: canvas.videoRect.midY), to: nil)
        #expect(workspace.hitTest(center) is TextCanvasView, "文字框上的点击没有落到文字编辑层")
        let corner = canvas.convert(CGPoint(x: canvas.videoRect.minX + 3, y: canvas.videoRect.minY + 3), to: nil)
        #expect(!(workspace.hitTest(corner) is TextCanvasView), "文字之外的点击也被编辑层接走了")
        model.textEditing = false
        #expect(!(workspace.hitTest(center) is TextCanvasView), "离开文字面板后编辑层还在吃点击")
    }

    private func findCanvasSurface(in view: NSView) -> CanvasSurfaceView? {
        if let surface = view as? CanvasSurfaceView { return surface }
        for child in view.subviews { if let found = findCanvasSurface(in: child) { return found } }
        return nil
    }
}

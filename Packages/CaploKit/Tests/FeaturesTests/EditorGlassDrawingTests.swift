import AppKit
import QuartzCore
import SwiftUI
import ProjectKit
import EditingCore
import Testing
@testable import Features

extension WindowLifecycleTests {
    @Test func glassEditorCompositeKeepsParentEnvironmentBehindNativeSurfaces() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // 只验证原生表面合成，不启动媒体解码或编码服务。
        let url = try ProjectStorage.create(in: root, name: "玻璃合成回归")
        try ProjectStorage.complete(url)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        defer { model.close() }
        model.edit.clips = [VideoClip(sourceStart: 0, duration: 4)]
        model.ready = true; model.loading = false
        let viewport = TimelineViewport()
        let editor = EditorWorkspaceView(model: model, viewport: viewport, addFocus: {})
        editor.frame = CGRect(x: 10, y: 10, width: 820, height: 600)
        editor.updateMaterialPreview(opaque: false, contrast: .standard)
        let stage = GlassEditorBackdrop(frame: CGRect(x: 0, y: 0, width: 840, height: 620))
        stage.wantsLayer = true; stage.addSubview(editor)
        let window = NSWindow(contentRect: stage.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = stage; window.orderFront(nil)
        defer { editor.tearDown(); window.contentView = nil; window.close() }
        stage.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
        try await Task.sleep(for: .milliseconds(40))
        let toolbar = try #require(editor.timelinePane.subviews.first { $0 is NSHostingView<AnyView> })
        let samples: [(NSView, CGPoint)] = [
            (editor.timelinePane.timeline, CGPoint(x: 300, y: 95)),
            (toolbar, CGPoint(x: 5, y: toolbar.bounds.midY)),
            (editor.canvas, CGPoint(x: 5, y: 5))
        ]
        #expect(!toolbar.isOpaque && toolbar.layer?.isOpaque == false)
        for _ in 0..<4 {
            editor.timelinePane.timeline.needsDisplay = true
            editor.needsDisplay = true
            window.displayIfNeeded(); CATransaction.flush()
            let bitmap = try #require(stage.bitmapImageRepForCachingDisplay(in: stage.bounds))
            stage.cacheDisplay(in: stage.bounds, to: bitmap)
            for (view, point) in samples {
                let position = view.convert(point, to: stage)
                let x = Int(position.x / stage.bounds.width * Double(bitmap.pixelsWide))
                let y = Int((stage.bounds.height - position.y) / stage.bounds.height * Double(bitmap.pixelsHigh))
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                #expect(color.alphaComponent > 0.99, "子视图合成不能擦掉不透明的父环境")
                #expect(max(color.redComponent, color.greenComponent, color.blueComponent) < 0.8,
                        "原生表面不能把低 alpha 白色画成白底")
            }
        }
    }

    @Test func glassTimelineRedrawErasesOldBlocksWithoutAccumulatingAlpha() throws {
        _ = NSApplication.shared
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            let context = try glassDrawingContext()
            let bounds = CGRect(x: 0, y: 0, width: 80, height: 40)
            EditorMaterialDrawing.drawPanel(in: bounds, appearance: appearance, context: context, flipped: true, opaqueOverride: false)
            let baseline = try glassDrawingBytes(context)
            #expect(!EditorMaterialDrawing.usesOpaqueSurface(appearance: appearance, opaqueOverride: false))
            let alpha = stride(from: 3, to: baseline.count, by: 4).map { baseline[$0] }
            #expect((alpha.max() ?? 255) < 128, "普通表面必须让后方环境透过")
            for _ in 0..<12 {
                // 模拟上一帧的片段、文字与拖动残影；下一帧只剩空时间线时应完全恢复。
                context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
                context.fill(CGRect(x: 10, y: 8, width: 48, height: 24))
                EditorMaterialDrawing.drawPanel(in: bounds, appearance: appearance, context: context, flipped: true, opaqueOverride: false)
                #expect(try glassDrawingBytes(context) == baseline)
            }
            // AppKit 可以只重绘 dirty clip：其内旧像素被清除，其外缓存不能被误擦除。
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(bounds)
            let old = try glassDrawingBytes(context)
            context.saveGState(); context.clip(to: CGRect(x: 0, y: 0, width: 40, height: 40))
            EditorMaterialDrawing.drawPanel(in: bounds, appearance: appearance, context: context, flipped: true, opaqueOverride: false)
            context.restoreGState()
            let partial = try glassDrawingBytes(context)
            for y in 0..<40 {
                let first = y * 80 * 4, middle = first + 40 * 4, end = first + 80 * 4
                #expect(partial[first..<middle] == baseline[first..<middle])
                #expect(partial[middle..<end] == old[middle..<end])
            }
        }
    }

    @Test func glassTimelineHighContrastAppearanceUsesOpaqueFallback() throws {
        _ = NSApplication.shared
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            let context = try glassDrawingContext()
            // AppKit 公开高对比名称仅供匹配；appearanceNamed 在本机将其退化成普通外观。
            // 显式注入审核意图，保持回退必须启用、全部像素必须不透明的严格断言。
            #expect(EditorMaterialDrawing.usesOpaqueSurface(appearance: appearance, opaqueOverride: true))
            EditorMaterialDrawing.drawPanel(in: CGRect(x: 0, y: 0, width: 80, height: 40), appearance: appearance,
                                             context: context, flipped: true, opaqueOverride: true)
            let bytes = try glassDrawingBytes(context)
            #expect(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 })
        }
    }

    private func glassDrawingContext() throws -> CGContext {
        try #require(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 80 * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }
    private func glassDrawingBytes(_ context: CGContext) throws -> [UInt8] {
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: context.bytesPerRow * context.height))
    }
}

@MainActor
private final class GlassEditorBackdrop: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: 1).setFill()
        bounds.fill()
    }
}

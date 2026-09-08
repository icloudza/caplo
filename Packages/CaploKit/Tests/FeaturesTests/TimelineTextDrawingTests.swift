import AppKit
import AVFoundation
import CoreText
import QuartzCore
import CaploDesignSystem
import EditingCore
import ProjectKit
import Testing
@testable import Features

extension WindowLifecycleTests {
    @Test func timelineTextUsesExplicitAppearanceAndContextAndKeepsItsDrawingState() throws {
        _ = NSApplication.shared
        let savedGraphics = NSGraphicsContext.current
        defer { NSGraphicsContext.current = savedGraphics }
        NSGraphicsContext.current = nil
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            let opposite = try #require(NSAppearance(named: name == .aqua ? .darkAqua : .aqua))
            let context = try textDrawingContext(width: 220, height: 60)
            let background = TimelineTextRenderer.resolvedColor(CaploNSColor.surfacePanel, appearance: appearance)
            context.setFillColor(background); context.fill(CGRect(x: 0, y: 0, width: 220, height: 60))
            context.textMatrix = CGAffineTransform(scaleX: 1.5, y: 0.75)
            context.textPosition = CGPoint(x: 12, y: 17)
            let matrix = context.ctm, textMatrix = context.textMatrix, textPosition = context.textPosition
            let before = try textDrawingBytes(context)
            var rendered = false
            opposite.performAsCurrentDrawingAppearance {
                // 使用崩溃栈里的原文本、动态颜色和 9pt 字号，并故意令全局外观与参数相反。
                rendered = TimelineTextRenderer.draw("00:00:08:00", in: CGRect(x: 8, y: 8, width: 100, height: 16),
                                                      color: CaploNSColor.textSecondary, size: 9,
                                                      appearance: appearance, context: context, flipped: false)
            }
            #expect(rendered)
            #expect(NSGraphicsContext.current == nil)
            #expect(context.ctm == matrix && context.textMatrix == textMatrix && context.textPosition == textPosition)
            let after = try textDrawingBytes(context)
            #expect(zip(before, after).filter { $0 != $1 }.count > 50)
            var expected: CGColor?
            appearance.performAsCurrentDrawingAppearance {
                expected = CaploNSColor.textSecondary.usingColorSpace(.sRGB)?.cgColor
            }
            // 蓝灰两档都使用浅色文字；验证显式外观不受相反的全局环境干扰，不再假定浅色必为黑字。
            var color = NSColor.clear.cgColor
            opposite.performAsCurrentDrawingAppearance {
                color = TimelineTextRenderer.resolvedColor(CaploNSColor.textSecondary, appearance: appearance)
            }
            let channels = try #require(color.components)
            let expectedChannels = try #require(expected?.components)
            #expect(channels.count == 4)
            #expect(zip(channels, expectedChannels).allSatisfy { abs($0 - $1) < 0.0001 })
        }
    }

    @Test func timelineTextClipsLongTitlesAndIgnoresInvalidRectangles() throws {
        _ = NSApplication.shared
        let appearance = try #require(NSAppearance(named: .aqua))
        let context = try textDrawingContext(width: 220, height: 60)
        context.setFillColor(TimelineTextRenderer.resolvedColor(CaploNSColor.surfacePanel, appearance: appearance))
        context.fill(CGRect(x: 0, y: 0, width: 220, height: 60))
        let before = try textDrawingBytes(context)
        #expect(TimelineTextRenderer.draw("录制画面 03 · 一个需要省略的很长标题", in: CGRect(x: 20, y: 10, width: 70, height: 20),
                                          color: CaploNSColor.textPrimary, size: 10, bold: true,
                                          appearance: appearance, context: context, flipped: true))
        let after = try textDrawingBytes(context)
        var changedPixels = 0
        for pixel in 0..<(220 * 60) {
            let start = pixel * 4
            guard before[start..<(start + 4)] != after[start..<(start + 4)] else { continue }
            changedPixels += 1
            #expect((20..<90).contains(pixel % 220))
        }
        #expect(changedPixels > 20)
        for rect in [CGRect.zero, CGRect(x: 0, y: 0, width: -1, height: 10),
                     CGRect(x: Double.nan, y: 0, width: 10, height: 10)] {
            #expect(!TimelineTextRenderer.draw("00:00:08:00", in: rect, color: CaploNSColor.textSecondary,
                                               appearance: appearance, context: context, flipped: true))
        }
        #expect(try textDrawingBytes(context) == after)
    }

    @Test func timelineTextSurvivesAppearanceScrollingZoomAndWindowResizeStress() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root, audio: true)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        defer { model.close() }
        // 复用测试素材构造长时间线，只绘制自身界面，不开启播放器或异步分析来干扰绘制压力。
        model.edit.clips = (0..<20).map { number in
            var clip = VideoClip(sourceStart: 0, duration: 4)
            clip.timelineStart = Double(number) * 4
            return clip
        }
        var focus = FocusSegment(start: 1, duration: 2, x: 0.5, y: 0.5)
        focus.timelineStart = 9; focus.targetClipID = model.edit.clips[2].id
        model.edit.focuses = [focus]
        model.edit.prepareLayerEditing(camera: false, system: false, microphone: true)
        model.edit.microphoneClips = Array((model.edit.microphoneClips ?? []).prefix(1))
        model.edit.rowGroups = [[model.edit.clips[2].id, model.edit.clips[3].id]]
        model.ready = true; model.loading = false
        let original = model.edit
        let viewport = TimelineViewport()
        let view = TimelineViewportView(model: model, viewport: viewport)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 260),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; view.autoresizingMask = [.width, .height]
        window.contentView = view; window.orderFront(nil)
        defer { view.detach(); window.contentView = nil; window.close() }
        let startingDraws = view.trackDrawCount
        var passes = 0
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = try #require(NSAppearance(named: name))
            for zoom in [-8.0, 0, 1, 4] {
                for size in [CGSize(width: 640, height: 180), CGSize(width: 960, height: 420),
                             CGSize(width: 1200, height: 240), CGSize(width: 740, height: 320)] {
                    try autoreleasepool {
                        viewport.zoom = zoom; viewport.fitRequest += 1
                        view.liveResizing = true
                        window.setContentSize(size)
                        view.update(edit: model.edit, analysis: model.analysis, selection: [], primary: nil, focus: nil,
                                    zoom: viewport.zoom, fit: viewport.fitRequest)
                        let horizontal = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                                             wheel1: 0, wheel2: -192, wheel3: 0))
                        horizontal.flags = []
                        view.scrollWheel(with: try #require(NSEvent(cgEvent: horizontal)))
                        let vertical = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                                           wheel1: passes.isMultiple(of: 2) ? -84 : 84, wheel2: 0, wheel3: 0))
                        vertical.flags = []
                        view.scrollWheel(with: try #require(NSEvent(cgEvent: vertical)))
                        view.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
                        // 窗口正常重绘和缓存上下文均执行一遍，覆盖 CGContext 生命周期与外观切换。
                        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                        #expect(try rulerTextInk(bitmap: bitmap, view: view) > 20,
                                "标尺文字缺失：\(name.rawValue)，缩放 \(zoom)，宽度 \(size.width)")
                        view.liveResizing = false
                        passes += 1
                    }
                }
            }
        }
        #expect(passes == 32 && view.trackDrawCount >= startingDraws + passes)
        #expect(model.edit == original && !model.history.canUndo)
        #expect(model.error == nil)
    }

    private func textDrawingContext(width: Int, height: Int) throws -> CGContext {
        try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func textDrawingBytes(_ context: CGContext) throws -> Data {
        let address = try #require(context.data)
        return Data(bytes: address, count: context.bytesPerRow * context.height)
    }

    private func rulerTextInk(bitmap: NSBitmapImageRep, view: TimelineViewportView) throws -> Int {
        let image = try #require(bitmap.cgImage)
        let scale = Double(image.width) / view.bounds.width
        let rect = CGRect(x: (TimelineViewportView.timeOrigin + 20) * scale, y: scale,
                          width: max(1, view.bounds.width - TimelineViewportView.timeOrigin - 36) * scale, height: 13 * scale)
        let ruler = try #require(image.cropping(to: rect))
        let context = try textDrawingContext(width: ruler.width, height: ruler.height)
        context.draw(ruler, in: CGRect(x: 0, y: 0, width: ruler.width, height: ruler.height))
        let bytes = try textDrawingBytes(context)
        let background = try #require(TimelineTextRenderer.resolvedColor(CaploNSColor.surfacePanel, appearance: view.effectiveAppearance).components)
        var ink = 0
        for pixel in 0..<(ruler.width * ruler.height) {
            let start = pixel * 4
            let difference = (0..<3).map { abs(Double(bytes[start + $0]) / 255 - background[$0]) }.max() ?? 0
            if difference > 0.12 { ink += 1 }
        }
        return ink
    }
}

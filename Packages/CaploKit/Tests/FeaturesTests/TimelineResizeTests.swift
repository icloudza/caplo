import AppKit
import AVFoundation
import QuartzCore
import EditingCore
import ProjectKit
import Testing
@testable import Features

extension WindowLifecycleTests {
    /// 用真实播放器时基和可见窗口的 CADisplayLink 验证连续跟随，避免只测计算函数而遗漏接线。
    @Test func playingMovesTheNavigatorWindowContinuouslyInsteadOfJumpingByPages() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        defer { model.close() }
        await model.open()
        try await waitForTimelinePlayback { model.ready && !model.loading && model.player.currentItem?.status == .readyToPlay }
        model.seek(0.5)
        try await waitForTimelinePlayback { abs(model.player.currentTime().seconds - 0.5) < 0.01 }

        let viewport = TimelineViewport()
        viewport.zoom = 4; viewport.fitRequest = 1
        let view = TimelineViewportView(model: model, viewport: viewport)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 260),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.autoresizingMask = [.width, .height]
        window.contentView = view; window.orderFront(nil)
        defer { view.detach(); window.contentView = nil; window.close() }
        view.update(edit: model.edit, analysis: model.analysis, selection: model.selectedClipIDs,
                    primary: model.selectedClip, focus: model.selectedFocus, zoom: viewport.zoom, fit: viewport.fitRequest)
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
        try await Task.sleep(for: .milliseconds(50))
        let navigator = try #require(view.subviews.compactMap { $0 as? TimelineNavigatorView }.first)
        let initialRect = navigator.visibleRangeRect
        #expect(window.isVisible && initialRect.width > 0)
        let originalEdit = model.edit
        let initialPosition = model.position
        let initialValue = navigator.accessibilityValue() as? String
        model.togglePlayback()
        try await waitForTimelinePlayback { model.playing && model.player.rate == 1 }
        defer { model.pause() }

        var priorX = initialRect.minX
        var priorTime = CACurrentMediaTime()
        var regularSamples = 0, movingSamples = 0
        var maximumStepInVisibleWidths = 0.0
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(30))
            let now = CACurrentMediaTime()
            let rect = navigator.visibleRangeRect
            let change = rect.minX - priorX
            // 超过 120ms 的调度停顿不能拿来判定单帧跳页，但仍要求足够正常样本和实际前进。
            if now - priorTime <= 0.12 {
                regularSamples += 1
                if change > 0.1 { movingSamples += 1 }
                maximumStepInVisibleWidths = max(maximumStepInVisibleWidths, abs(change) / max(1, rect.width))
                #expect(change >= -0.5)
            }
            priorX = rect.minX; priorTime = now
        }
        #expect(regularSamples >= 10 && movingSamples >= 5)
        #expect(maximumStepInVisibleWidths < 0.5)
        #expect(navigator.visibleRangeRect.minX - initialRect.minX > initialRect.width * 0.2)
        #expect(navigator.accessibilityValue() as? String != initialValue)
        #expect(model.position > initialPosition + 0.6)
        #expect(model.edit == originalEdit && !model.history.canUndo)
        #expect(model.error == nil)
    }

    /// 直接检查自身窗口已提交的图层内容；不能用 cacheDisplay 强制绘制后才检查，
    /// 否则分界拖动期间遗留在旧底部的滚动条、旧行位图会被测试本身擦掉。
    @Test func liveTimelineResizeDoesNotLeaveOldRowsOrNavigatorAtThePreviousBottom() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root, audio: true)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        defer { model.close() }
        // 重复引用同一份 4 秒测试素材，构造横向和纵向均溢出的时间线；此测试只渲染编辑器，
        // 不开启播放器或后台媒体分析，以免异步波形变化污染前后像素比较。
        model.edit.clips = (0..<20).map { number in
            var clip = VideoClip(sourceStart: 0, duration: 4)
            clip.timelineStart = Double(number) * 4
            return clip
        }
        model.edit.prepareLayerEditing(camera: false, system: false, microphone: true)
        model.edit.microphoneClips = Array((model.edit.microphoneClips ?? []).prefix(1))
        model.ready = true; model.loading = false
        let viewport = TimelineViewport()
        let view = TimelineViewportView(model: model, viewport: viewport)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 260),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        view.autoresizingMask = [.width, .height]
        window.contentView = view; window.orderFront(nil)
        defer { view.detach(); window.contentView = nil; window.close() }
        view.update(edit: model.edit, analysis: model.analysis, selection: [], primary: nil, focus: nil,
                    zoom: 0, fit: viewport.fitRequest)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded(); CATransaction.flush()
        try await Task.sleep(for: .milliseconds(30))
        let navigator = try #require(view.subviews.first { $0 is TimelineNavigatorView })

        view.liveResizing = true; viewport.liveResizing = true
        defer { viewport.liveResizing = false; view.liveResizing = false }
        for atBottom in [false, true] {
            if atBottom {
                // 扩高会重新约束 verticalOffset；轨头按钮已经改位置时，行背景也必须刷新。
                window.setContentSize(CGSize(width: 960, height: 200))
                view.layoutSubtreeIfNeeded()
                let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                                 wheel1: -10_000, wheel2: 0, wheel3: 0))
                wheel.flags = []
                view.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
                window.displayIfNeeded(); CATransaction.flush()
            }
            for height in [260.0, 430, 200, 470] {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                window.setContentSize(CGSize(width: 960, height: height))
                view.layoutSubtreeIfNeeded()
                CATransaction.commit()
                window.displayIfNeeded(); CATransaction.flush()
                try await Task.sleep(for: .milliseconds(20))
                #expect(view.liveResizing && viewport.liveResizing)
                #expect(abs(navigator.frame.minY - (view.bounds.height - TimelineNavigatorView.preferredHeight)) < 0.5)
                #expect(abs(navigator.frame.maxY - view.bounds.height) < 0.5)
                #expect(abs(navigator.frame.minX - TimelineViewportView.timeOrigin) < 0.5)
                #expect(abs(navigator.frame.width - (view.bounds.width - TimelineViewportView.timeOrigin - 8)) < 0.5)

                // 第一张只读取现有 CALayer 内容；第二张才显式强制重绘，几何和交互状态完全相同。
                let cached = try timelineResizePixels(view)
                view.needsDisplay = true
                navigator.needsDisplay = true
                window.displayIfNeeded(); CATransaction.flush()
                let freshlyDrawn = try timelineResizePixels(view)
                #expect(cached.contains { $0 != 0 && $0 != 255 })
                #expect(cached == freshlyDrawn,
                        "分界拖动中旧位图未刷新：高度 \(height)，起始是否滚到底部 \(atBottom)")
            }
        }
    }

    private func timelineResizePixels(_ view: NSView) throws -> Data {
        let layer = try #require(view.layer)
        let scale = view.window?.backingScaleFactor ?? 1
        let width = Int(ceil(view.bounds.width * scale)), height = Int(ceil(view.bounds.height * scale))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        let data = try #require(context.makeImage()?.dataProvider?.data)
        return data as Data
    }

    private func waitForTimelinePlayback(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "真实时间线播放未在等待期限内就绪")
    }
}

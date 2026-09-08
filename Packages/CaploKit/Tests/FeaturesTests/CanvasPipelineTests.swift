import AVFoundation
import AppKit
import CoreImage
import Testing
import ProjectKit
import EditingCore
import ExportKit
@testable import Features

extension WindowLifecycleTests {
    /// 暂停的播放项换合成后原地定位一次，必须拿到按新合成渲染的当前帧（系统不保证换合成后自动重画，
    /// 播放过再暂停之后常常停在旧画面上；编辑器在暂停时换合成都会这样定位一次）。
    @Test func pausedPlayerRerendersWhenCompositionChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root)
        let document = try ProjectStorage.load(url)
        var edit = VideoEdit(duration: document.duration)
        edit.layout.padding = 0; edit.layout.cornerRadius = 0; edit.layout.shadow = false
        let item = try await ProjectMedia.playerItem(url: url, document: document, levels: edit.audio, edit: edit)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        for _ in 0..<300 where item.status != .readyToPlay { try await Task.sleep(for: .milliseconds(20)) }
        #expect(item.status == .readyToPlay)
        await player.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        func pull(timeout: Int) async throws -> (CVPixelBuffer, Double)? {
            let start = Date()
            for _ in 0..<timeout {
                let time = item.currentTime()
                if output.hasNewPixelBuffer(forItemTime: time), let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                    return (buffer, Date().timeIntervalSince(start))
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            return nil
        }
        func corner(_ buffer: CVPixelBuffer) -> (r: Int, g: Int, b: Int) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            let o = 6 * row + 6 * 4
            return (Int(base[o + 2]), Int(base[o + 1]), Int(base[o]))
        }
        /// 编辑器暂停时换合成的做法：换完原地定位一次。
        func swap(previous: VideoEdit, next: VideoEdit) async throws {
            try ProjectMedia.updatePresentation(item: item, previous: previous, edit: next, url: url)
            await player.seek(to: item.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        let first = try #require(try await pull(timeout: 600))
        let firstPixel = corner(first.0)
        print("首帧耗时 \(Int(first.1 * 1000)) ms，角落像素 \(firstPixel)，尺寸 \(CVPixelBufferGetWidth(first.0))×\(CVPixelBufferGetHeight(first.0))")
        #expect(firstPixel.r > 150 && firstPixel.b < 90, "留白 0 时角落应是红色视频")
        // 先播放一小段再暂停（用户报告的场景），然后换合成：留白 120，角落应变成背景渐变。
        player.play()
        try await Task.sleep(for: .milliseconds(300))
        player.pause()
        _ = try await pull(timeout: 100)
        var padded = edit; padded.layout.padding = 120
        let swapStart = Date()
        try await swap(previous: edit, next: padded)
        let second = try #require(try await pull(timeout: 600), "暂停后换合成并原地定位，必须拿到新帧")
        let secondPixel = corner(second.0)
        print("换合成后新帧耗时 \(Int(Date().timeIntervalSince(swapStart) * 1000)) ms，角落像素 \(secondPixel)")
        // 判定不绑定默认渐变的具体数值：背景是蓝系（蓝通道明显高于红），红色视频不是。
        #expect(secondPixel.b > secondPixel.r + 40 && secondPixel.r < 150, "留白 120 时角落应是背景")
        // 连续快速换合成 30 次，统计每次拿到新帧的耗时。
        var latencies: [Double] = []
        for step in 1...30 {
            var next = padded; next.layout.padding = Double(20 + step * 2)
            let previous = padded; padded = next
            let begin = Date()
            try await swap(previous: previous, next: next)
            if let frame = try await pull(timeout: 200) { latencies.append(Date().timeIntervalSince(begin)); _ = frame }
        }
        print("连续换合成 30 次：拿到新帧 \(latencies.count) 次，平均 \(Int((latencies.reduce(0, +) / Double(max(1, latencies.count))) * 1000)) ms，最大 \(Int((latencies.max() ?? 0) * 1000)) ms")
        #expect(latencies.count >= 25)
    }
}

extension WindowLifecycleTests {
    /// 视图尺寸一变，成片图层几何必须在同一次调用里就位（不等 layout），否则拖动分界时成片会晚一帧。
    @Test func canvasSurfaceUpdatesGeometrySynchronouslyWithFrameChanges() {
        // 300 点高时受高度限制；拉高到 700 点后成片应立即随之变大。
        let view = CanvasSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 300))
        view.aspectRatio = 16.0 / 9
        let first = view.videoRect
        #expect(first.width > 0 && abs(first.width / first.height - 16.0 / 9) < 0.02)
        #expect(first.minX >= CanvasSurfaceView.inset - 0.5 && first.minY >= CanvasSurfaceView.inset - 0.5)
        view.setFrameSize(NSSize(width: 800, height: 700))
        let second = view.videoRect
        #expect(second.height > first.height, "视口变高后成片应立即变大：\(first) → \(second)")
        #expect(abs(second.midX - 400) < 1 && abs(second.midY - 350) < 1)
        view.aspectRatio = 9.0 / 16
        let portrait = view.videoRect
        #expect(abs(portrait.width / portrait.height - 9.0 / 16) < 0.02)
    }
}

extension WindowLifecycleTests {
    /// 裁剪拖动期间播放项不重建、不进入载入态，画布显示裁剪边缘那一帧；松手后才静默重建。
    @Test func trimDragKeepsPlayerItemAndRebuildsSilentlyOnRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        defer { model.close() }
        await model.open()
        for _ in 0..<300 where model.loading || model.player.currentItem?.status != .readyToPlay { try await Task.sleep(for: .milliseconds(20)) }
        let item = try #require(model.player.currentItem)
        let id = model.edit.clips[0].id
        model.beginInteraction()
        // 拖尾边到 1.5 秒：边缘帧在旧播放项里存在，应由播放器定位显示，且是前两秒的红色画面。
        model.edit.resize(id: id, sourceStart: 0, sourceEnd: 1.5, sourceDuration: 4)
        model.previewChanged(edgeSource: 1.5 - 1.0 / 60)
        #expect(model.player.currentItem === item)
        #expect(!model.loading && !model.rebuilding)
        var sawRed = false
        for _ in 0..<200 {
            if let image = model.canvas.snapshot(), isRedFrame(image), abs(model.player.currentTime().seconds - (1.5 - 1.0 / 60)) < 0.05 { sawRed = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sawRed, "裁剪边缘帧应来自播放器定位")
        #expect(model.player.currentItem === item, "拖动期间不能重建播放项")
        model.endInteraction()
        #expect(model.edit.clips[0].duration == 1.5)
        #expect(!model.loading, "静默重建不显示载入画面")
        for _ in 0..<300 where model.rebuilding { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.player.currentItem !== item && !model.rebuilding && !model.loading)
    }

    /// 缩略图缓存：片段起点精确到帧（红 / 蓝素材在 2 秒处切换），网格取帧就近；命中后不再登记请求。
    @Test func thumbnailStoreDeliversExactFramesForClipStarts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root)
        let store = ThumbnailStore(url: url, document: try ProjectStorage.load(url))
        defer { store.close() }
        var changes = 0
        store.onChange = { changes += 1 }
        #expect(store.image(at: 2.5, exact: true) == nil)
        #expect(store.image(at: 1.0, exact: false) == nil)
        var blue: CGImage?, red: CGImage?
        for _ in 0..<300 {
            blue = store.image(at: 2.5, exact: true); red = store.image(at: 1.0, exact: false)
            if blue != nil, red != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let blueImage = try #require(blue), redImage = try #require(red)
        #expect(!isRedFrame(blueImage) && isRedFrame(redImage))
        #expect(changes >= 2 && store.cachedCount == 2)
        // 就在切换点之后一点点的精确请求也必须是蓝色，而不是就近关键帧的红色。
        for _ in 0..<300 where store.image(at: 2.05, exact: true) == nil { try await Task.sleep(for: .milliseconds(20)) }
        let edge = try #require(store.image(at: 2.05, exact: true))
        #expect(!isRedFrame(edge))
    }

    func isRedFrame(_ image: CGImage) -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(CIImage(cgImage: image), toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return pixel[0] > 150 && pixel[2] < 80
    }
}

extension WindowLifecycleTests {
    /// 用户场景：播放过再暂停，改会换合成的参数（这里用留白，光标样式同一条路径）后画布必须显示按新合成重画的当前帧，
    /// 不能停在旧画面上，也不能换到别的时间。
    @Test func pausedEditorCanvasFollowsPresentationChanges() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        defer { model.close() }
        await model.open()
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
            Issue.record("等待超时")
        }
        try await wait { !model.loading && model.player.currentItem?.status == .readyToPlay && model.canvas.frame != nil }
        model.commit { $0.layout.padding = 0; $0.layout.cornerRadius = 0; $0.layout.shadow = false }
        model.seek(0.5)
        try await wait { model.canvas.snapshot().map { isRedFrame($0) && isRedCorner($0) } == true }
        model.togglePlayback()
        try await Task.sleep(for: .milliseconds(300))
        model.pause()
        try await Task.sleep(for: .milliseconds(100))
        let paused = model.player.currentTime().seconds
        model.commit { $0.layout.padding = 120 }
        try await wait { model.canvas.snapshot().map { !isRedCorner($0) } == true }
        #expect(model.canvas.snapshot().map { isRedFrame($0) && !isRedCorner($0) } == true, "留白 120 后角落应是背景、中心仍是视频")
        #expect(abs(model.player.currentTime().seconds - paused) < 0.05, "原地重画不能换到别的时间")
        #expect(!model.playing && model.error == nil)
    }

    /// 左下角 6×6 处是否仍是红色视频（留白后应是背景）。
    func isRedCorner(_ image: CGImage) -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(CIImage(cgImage: image), toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 6, y: 6, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return pixel[0] > 150 && pixel[2] < 80
    }
}


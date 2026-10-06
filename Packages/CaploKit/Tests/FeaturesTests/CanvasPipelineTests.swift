import AVFoundation
import AppKit
import CoreImage
import Testing
import ProjectKit
import RenderKit
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

}

extension WindowLifecycleTests {

}


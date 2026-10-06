import Foundation
import AVFoundation
import CoreImage
import ImageIO
import Testing
import ProjectKit
import ExportKit
import EditingCore
import RenderKit
@testable import CaptureKit

/// 导出亮度必须与原录制一致：合成器在解码端认的那个 709 空间（CoreMedia 709）里渲染、也标 709。
/// 以前按 sRGB 曲线写却标 709，中灰被抬约 10 级；换成 `CGColorSpace.itur_709` 也不对，抬约 15 级。
/// 均匀中灰经过编码与缩放都不变，两边差异只可能来自色彩曲线。
@Test @MainActor func exportKeepsTheRecordedBrightness() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "亮度")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: false, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) { writer.ingest(try makeFrame(at: CMTime(seconds: 10, preferredTimescale: 600)), role: .screen) }
    try await writer.finish(at: CMTime(seconds: 10.5, preferredTimescale: 600))
    let document = try ProjectStorage.load(url)
    let target = root.appendingPathComponent("gray.mp4")
    try await ProjectMedia.export(url: url, document: document, levels: AudioLevels(), destination: target, edit: VideoEdit(duration: document.duration)) { _ in }
    let source = try await centerLevel(of: try ProjectStorage.mediaURL(document.segments[0].files[.screen]!, in: url))
    let exported = try await centerLevel(of: target)
    #expect(abs(source - exported) <= 3, "原录制 \(source)，导出 \(exported)")
}

/// 卡片导出成"背景 + 文字"、不带录屏：卡片这段画面轨留空，合成器按卡片画；成片因卡片变长。
/// 合成时若把卡片当成普通片段插素材，卡片中间会出现录屏的第一帧。
@Test @MainActor func cardsExportAsTheirOwnBackgroundInsteadOfTheRecording() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "卡片导出")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: true, microphone: false, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) {
        writer.ingest(try makeFrame(at: CMTime(seconds: 10, preferredTimescale: 600)), role: .screen)
        writer.ingest(try makeAudio(at: CMTime(seconds: 10, preferredTimescale: 600), duration: 2, channels: 2), role: .systemAudio)
    }
    try await writer.finish(at: CMTime(seconds: 12, preferredTimescale: 600))
    let document = try ProjectStorage.load(url)
    var edit = VideoEdit(duration: document.duration)
    let inserted = edit.insertCard(at: 1, duration: 1.5)
    let card = try #require(inserted)
    edit.updateCard(id: card) { $0.background = .ink; $0.text.text = "" }
    let target = root.appendingPathComponent("card.mp4")
    try await ProjectMedia.export(url: url, document: document, levels: edit.audio, destination: target, edit: edit) { _ in }
    #expect(abs(try await AVURLAsset(url: target).load(.duration).seconds - 3.5) < 0.05)
    let before = try await centerLevel(of: target, at: 0.5), inside = try await centerLevel(of: target, at: 1.75), after = try await centerLevel(of: target, at: 3)
    #expect(inside < 40, "卡片中间是 \(inside)，不是墨色背景")
    #expect(abs(before - after) <= 3 && before > 100, "卡片前后的录屏是 \(before) / \(after)")
}

/// 导出窗口里的每种格式都得到对应的编码：HEVC 写 hvc1、ProRes 写 apcn（422），关掉声音就没有音轨；
/// GIF 按自己的帧率出帧（2 秒 15 帧 = 30 帧），不被视频合成的帧率下限抬到 24。
@Test @MainActor func exportFormatsProduceTheChosenEncoding() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "格式")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: true, microphone: false, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) {
        writer.ingest(try makeFrame(at: CMTime(seconds: 10, preferredTimescale: 600)), role: .screen)
        writer.ingest(try makeAudio(at: CMTime(seconds: 10, preferredTimescale: 600), duration: 2, channels: 2), role: .systemAudio)
    }
    try await writer.finish(at: CMTime(seconds: 12, preferredTimescale: 600))
    let document = try ProjectStorage.load(url)
    let edit = VideoEdit(duration: document.duration)
    for (format, codec) in [(ExportSettings.Format.hevc, "hvc1"), (.proRes, "apcn")] {
        var settings = ExportSettings(); settings.format = format; settings.includesAudio = false; settings.resolution = .p720
        let target = root.appendingPathComponent("\(format.rawValue).\(format.fileExtension)")
        try await ProjectMedia.export(url: url, document: document, levels: edit.audio, destination: target, edit: edit, settings: settings) { _ in }
        let asset = AVURLAsset(url: target)
        let description = try #require(try await asset.loadTracks(withMediaType: .video).first?.load(.formatDescriptions).first)
        let type = CMFormatDescriptionGetMediaSubType(description)
        #expect(String(format: "%c%c%c%c", (type >> 24) & 255, (type >> 16) & 255, (type >> 8) & 255, type & 255) == codec)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
    }
    var gif = ExportSettings(); gif.format = .gif; gif.resolution = .p480; gif.gifFrameRate = 15
    let target = root.appendingPathComponent("demo.gif")
    try await ProjectMedia.export(url: url, document: document, levels: edit.audio, destination: target, edit: edit, settings: gif) { _ in }
    let source = try #require(CGImageSourceCreateWithURL(target as CFURL, nil))
    #expect(CGImageSourceGetCount(source) == 30, "GIF 有 \(CGImageSourceGetCount(source)) 帧")
}

/// 缩小到一半以下走 Lanczos：一像素宽的黑白细线应融成均匀的灰。
/// Core Image 自带的高质量缩小只在约 0.4 倍以下生效，0.4…0.5 倍之间直接仿射缩放会把细线缩成粗细不一的条纹（摩尔纹）——
/// 4K 录屏放进 1080p 成片、镜头拉远时正落在这一段。
@Test func largeDownscalesAverageFineDetailInsteadOfAliasing() {
    let width = 400, height = 64
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height { for x in 0..<width where x % 2 == 0 { let p = (y * width + x) * 4; pixels[p] = 0; pixels[p + 1] = 0; pixels[p + 2] = 0 } }
    let stripes = CIImage(bitmapData: Data(pixels), bytesPerRow: width * 4, size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    let shrink = CGAffineTransform(scaleX: 0.45, y: 0.45)
    #expect(spread(of: SceneRenderer.resampled(stripes, by: shrink)) < 12)
    #expect(spread(of: stripes.transformed(by: shrink)) > 40, "对照组应当出现摩尔纹，否则这条测试测不到东西")
}

/// 画面正中一个像素的灰度（按色彩标签解读后落到 sRGB）。
private func centerLevel(of url: URL, at seconds: Double = 0) async throws -> Double {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = seconds == 0 ? .positiveInfinity : .zero
    let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    var pixel = [UInt8](repeating: 0, count: 4)
    CIContext().render(CIImage(cgImage: image), toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 3
}

/// 缩小后中间一行的最大与最小灰度之差：越小越均匀。
private func spread(of image: CIImage) -> Int {
    let extent = image.extent.integral
    let row = CGRect(x: extent.minX + 2, y: extent.midY.rounded(.down), width: extent.width - 4, height: 1)
    var pixels = [UInt8](repeating: 0, count: Int(row.width) * 4)
    CIContext().render(image, toBitmap: &pixels, rowBytes: Int(row.width) * 4, bounds: row, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    let levels = stride(from: 0, to: pixels.count, by: 4).map { Int(pixels[$0]) }
    return (levels.max() ?? 0) - (levels.min() ?? 0)
}

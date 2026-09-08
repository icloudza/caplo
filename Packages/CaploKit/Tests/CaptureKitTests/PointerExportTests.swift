import AVFoundation
import AppKit
import CoreImage
import Testing
import EditingCore
import ProjectKit
import ExportKit
import RenderKit
@testable import CaptureKit

/// 对效果覆盖的像素单独比较，避免整幅画面平均值掩盖小光标或点击圆环完全丢失。
@Test(arguments: [0, 1, 2]) @MainActor func pointerExportMatchesPreviewAtAffectedPixelsAfterTrimAndZoom(mode: Int) async throws {
    let enhanced = mode > 0
    let native = mode == 2 ? NativeCursorCapture.capture(NSCursor.crosshair) : nil
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "光标导出")
    var initial = try ProjectStorage.load(url)
    initial.capture = CaptureMetadata(desktopBounds: CGRect(x: 0, y: 0, width: 320, height: 180), pixelSize: CGSize(width: 320, height: 180), pointPixelScale: 1, pointerEnabled: true)
    initial.capture?.cursorEmbedded = false
    try ProjectStorage.save(initial, to: url)
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: false, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) { writer.ingest(try makeFrame(at: CMTime(seconds: 10, preferredTimescale: 600)), role: .screen) }
    for index in 0..<60 {
        let time = Double(index) / 30
        var sample = PointerSample(time: 10 + time, x: 0.6 + (enhanced ? sin(time * 3) * 0.12 : 0), y: 0.5, kind: .move)
        sample.cursorAssetID = native?.id
        writer.appendPointer(sample, cursor: native)
    }
    writer.appendPointer(PointerSample(time: 10.25, x: 0.6, y: 0.5, kind: .click))
    try await writer.finish(at: CMTime(seconds: 12, preferredTimescale: 600))
    let document = try ProjectStorage.load(url)
    var edit = try EditStorage.load(in: url, document: document)
    #expect(edit.pointer != nil)
    edit.pointer?.cursorScale = 2; edit.pointer?.clickScale = 1.5; edit.pointer?.tint = .yellow
    if enhanced {
        edit.pointer?.style = .tahoe; edit.pointer?.smoothing = 0.5; edit.pointer?.bounce = 0.2
        edit.pointer?.motionBlur = 0.4; edit.pointer?.sway = 0.3; edit.pointer?.clickEffect = .echo
    }
    if mode == 2 { edit.pointer?.style = .captured; #expect(native != nil) }
    edit.clips = [VideoClip(sourceStart: 0.1, duration: 1.5)]
    edit.focuses = [FocusSegment(start: 0, duration: 2, x: 0.6, y: 0.5, scale: 1.8)]
    let target = root.appendingPathComponent("pointer.mp4")
    try await ProjectMedia.export(url: url, document: document, levels: edit.audio, destination: target, edit: edit) { _ in }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: target))
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    let exported = try await generator.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)).image
    let renderer = EditorPreviewRenderer()
    let preview = try await renderer.render(url: url, document: document, edit: edit, time: 0.3)
    var plain = edit; plain.pointer = nil
    let baseline = try await renderer.render(url: url, document: document, edit: plain, time: 0.3)
    let size = CGSize(width: 1280, height: 720), context = CIContext()
    func pixels(_ image: CGImage) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 1280 * 720 * 4)
        let input = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: size.width / Double(image.width), y: size.height / Double(image.height)))
        context.render(input, toBitmap: &result, rowBytes: 1280 * 4, bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return result
    }
    let expected = pixels(preview), base = pixels(baseline), actual = pixels(exported)
    var affected = 0, matched = 0
    for index in stride(from: 0, to: expected.count, by: 4) {
        let change = (0..<3).map { abs(Int(expected[index + $0]) - Int(base[index + $0])) }.max()!
        if change > 45 {
            affected += 1
            if (0..<3).allSatisfy({ abs(Int(expected[index + $0]) - Int(actual[index + $0])) < 30 }) { matched += 1 }
        }
    }
    #expect(affected > 500)
    #expect(Double(matched) / Double(max(1, affected)) > 0.85)
    let item = try await ProjectMedia.playerItem(url: url, document: document, levels: edit.audio, edit: edit)
    let first = try #require(item.videoComposition?.instructions.first as? SceneInstruction)
    #expect(first.pointerFrame(at: 0.3).position != nil && first.pointerFrame(at: 0.3).clicks.count == 1)
    var hidden = edit; hidden.pointer?.cursorVisible = false; hidden.pointer?.clicksVisible = false
    try ProjectMedia.updatePresentation(item: item, previous: edit, edit: hidden)
    let changed = try #require(item.videoComposition?.instructions.first as? SceneInstruction)
    #expect(changed.pointerFrame(at: 0.3).position == nil && changed.pointerFrame(at: 0.3).clicks.isEmpty)
    await renderer.close()
}

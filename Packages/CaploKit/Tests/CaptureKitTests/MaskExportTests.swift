import AVFoundation
import AppKit
import CoreImage
import Testing
import EditingCore
import ProjectKit
import ExportKit
import RenderKit
@testable import CaptureKit

/// 导出与预览必须给出同一张打过码的画面，项目封面也不能露出原文。
/// 这里跑的是真正的导出管线（写文件、再从文件里取帧），不是离线渲染。
private let maskSpace = CGColorSpace(name: CGColorSpace.sRGB)!

/// 竖条纹帧：一列黑一列白，模糊或像素化生效后立刻变成一片灰。
private func stripedFrame(at time: CMTime, width: Int = 320, height: Int = 180) throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                              [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess,
          let pixel else { throw RecordingError.message("测试像素缓冲创建失败") }
    CVPixelBufferLockBaseAddress(pixel, [])
    if let base = CVPixelBufferGetBaseAddress(pixel) {
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = (x / 2) % 2 == 0 ? 255 : 0
                for channel in 0..<3 { bytes[y * stride + x * 4 + channel] = value }
                bytes[y * stride + x * 4 + 3] = 255
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pixel, [])
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format) == noErr,
          let format else { throw RecordingError.message("测试视频描述创建失败") }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format,
                                                   sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
          let sample else { throw RecordingError.message("测试视频帧创建失败") }
    return sample
}

/// 相邻像素亮度差超过 32 的比例；竖条纹原图约 0.5，糊掉之后趋近 0。
private func edgeDensity(_ image: CGImage, box: CGRect) -> Double {
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: maskSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let x0 = max(0, Int(box.minX)), x1 = min(width - 1, Int(box.maxX))
    let y0 = max(0, Int(box.minY)), y1 = min(height, Int(box.maxY))
    guard x1 > x0 + 1, y1 > y0 else { return 0 }
    var edges = 0, count = 0
    for y in y0..<y1 {
        for x in x0..<(x1 - 1) {
            let a = Int(bytes[(y * width + x) * 4]), b = Int(bytes[(y * width + x + 1) * 4])
            if abs(a - b) > 32 { edges += 1 }
            count += 1
        }
    }
    return count > 0 ? Double(edges) / Double(count) : 0
}

@MainActor
private func makeStripedProject(_ root: URL, name: String) async throws -> (url: URL, document: ProjectDocument) {
    let url = try ProjectStorage.create(in: root, name: name)
    var initial = try ProjectStorage.load(url)
    initial.capture = CaptureMetadata(desktopBounds: CGRect(x: 0, y: 0, width: 320, height: 180),
                                      pixelSize: CGSize(width: 320, height: 180), pointPixelScale: 1, pointerEnabled: false)
    try ProjectStorage.save(initial, to: url)
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: false, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) { writer.ingest(try stripedFrame(at: CMTime(seconds: 10, preferredTimescale: 600)), role: .screen) }
    try await writer.finish(at: CMTime(seconds: 12, preferredTimescale: 600))
    return (url, try ProjectStorage.load(url))
}

@Test @MainActor func exportedFileCarriesTheMaskAndMatchesThePreview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try await makeStripedProject(root, name: "遮罩导出")
    var edit = try EditStorage.load(in: project.url, document: project.document)
    edit.layout.padding = 0; edit.layout.cornerRadius = 0; edit.layout.shadow = false
    edit.addMask(MaskSegment(start: 0, duration: 2, x: 0.5, y: 0.5, width: 0.5, height: 0.5, effect: .blur, amount: 40))
    try EditStorage.save(edit, in: project.url, document: project.document)

    let target = root.appendingPathComponent("mask.mp4")
    try await ProjectMedia.export(url: project.url, document: project.document, levels: edit.audio, destination: target, edit: edit) { _ in }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: target))
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    let exported = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image

    // 导出画面按长边 1920 渲染；遮住的是正中一半，取更保守的中央三分之一来量。
    let width = Double(exported.width), height = Double(exported.height)
    let inside = CGRect(x: width / 3, y: height / 3, width: width / 3, height: height / 3)
    let outside = CGRect(x: 4, y: 4, width: width / 8, height: height / 8)
    #expect(edgeDensity(exported, box: inside) < 0.02, "导出的遮罩区域还剩 \(edgeDensity(exported, box: inside)) 的边缘密度")
    #expect(edgeDensity(exported, box: outside) > 0.2, "遮罩之外被误伤了，只剩 \(edgeDensity(exported, box: outside)) 的边缘密度")

    // 预览走的是另一条调用路径（离线渲染器），必须给出同样的结果。
    let renderer = EditorPreviewRenderer()
    let preview = try await renderer.render(url: project.url, document: project.document, edit: edit, time: 0.5)
    await renderer.close()
    let previewInside = CGRect(x: Double(preview.width) / 3, y: Double(preview.height) / 3,
                               width: Double(preview.width) / 3, height: Double(preview.height) / 3)
    #expect(edgeDensity(preview, box: previewInside) < 0.02, "预览的遮罩区域还剩 \(edgeDensity(preview, box: previewInside)) 的边缘密度")
}

@Test @MainActor func projectThumbnailIsMaskedAndRefusesToGuessWhenUnreadable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try await makeStripedProject(root, name: "遮罩封面")
    let bare = try await ProjectMedia.thumbnail(url: project.url, document: project.document)
    let full = CGRect(x: 0, y: 0, width: Double(bare.width), height: Double(bare.height))
    #expect(edgeDensity(bare, box: full) > 0.2)

    var edit = try EditStorage.load(in: project.url, document: project.document)
    // 遮住整幅画面：封面是原素材首帧，不经画布布局，所以直接量全图。
    edit.addMask(MaskSegment(start: 0, duration: 2, x: 0.5, y: 0.5, width: 1.4, height: 1.4, effect: .pixelate, amount: 60))
    try EditStorage.save(edit, in: project.url, document: project.document)
    let masked = try await ProjectMedia.thumbnail(url: project.url, document: project.document)
    #expect(edgeDensity(masked, box: full) < 0.06, "封面还剩 \(edgeDensity(masked, box: full)) 的边缘密度")

    // 编辑文件坏掉时宁可没有封面，也不能给一张没打码的原帧。
    try Data("{ 这不是 JSON".utf8).write(to: project.url.appendingPathComponent("edits.json"))
    await #expect(throws: (any Error).self) { try await ProjectMedia.thumbnail(url: project.url, document: project.document) }
}

/// 导出的两帧逐像素比较：只在文字覆盖的地方不同。
private func pixels(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int)? {
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: maskSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (bytes, width, height)
}

@MainActor
private func exportFrame(_ project: (url: URL, document: ProjectDocument), edit: VideoEdit, to target: URL, at time: Double) async throws -> CGImage {
    try EditStorage.save(edit, in: project.url, document: project.document)
    try await ProjectMedia.export(url: project.url, document: project.document, levels: edit.audio, destination: target, edit: edit) { _ in }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: target))
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
}

@Test @MainActor func exportedFileCarriesTheTextLayer() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try await makeStripedProject(root, name: "文字导出")
    var edit = try EditStorage.load(in: project.url, document: project.document)
    edit.layout.padding = 0; edit.layout.cornerRadius = 0; edit.layout.shadow = false
    let plainFrame = try await exportFrame(project, edit: edit, to: root.appendingPathComponent("plain.mp4"), at: 1)

    var label = TextPreset.bigNumber.segment(start: 0, duration: 2)
    label.text = "3×"; label.color = .white; label.shadow = false
    label.enterKind = .none; label.exitKind = .none; label.enterDuration = 0; label.exitDuration = 0
    edit.addText(label)
    let textFrame = try await exportFrame(project, edit: edit, to: root.appendingPathComponent("text.mp4"), at: 1)

    let plain = try #require(pixels(plainFrame)), withText = try #require(pixels(textFrame))
    #expect(plain.width == withText.width && plain.height == withText.height)
    let width = plain.width, height = plain.height
    func changed(in box: CGRect) -> Int {
        var count = 0
        for y in Int(box.minY)..<Int(box.maxY) {
            for x in Int(box.minX)..<Int(box.maxX) {
                let offset = (y * width + x) * 4
                if abs(Int(plain.bytes[offset]) - Int(withText.bytes[offset])) > 60 { count += 1 }
            }
        }
        return count
    }
    // 大数字预设居中：中央三分之一里有成片的像素被改写。
    let center = CGRect(x: width / 3, y: height / 3, width: width / 3, height: height / 3)
    #expect(changed(in: center) > 4000, "导出的画面中央只有 \(changed(in: center)) 个像素被文字改写")
    // 四角不该被碰到——文字最大宽度是 0.9，上下也够不着。
    let corner = CGRect(x: 0, y: 0, width: Double(width) / 8, height: Double(height) / 8)
    #expect(changed(in: corner) == 0, "文字之外有 \(changed(in: corner)) 个像素被改动了")
}

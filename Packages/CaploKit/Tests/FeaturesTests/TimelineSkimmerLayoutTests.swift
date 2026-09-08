import AppKit
import Testing
import ProjectKit
@testable import Features

/// 悬停时间码：底板贴着文字，文字按行高在底板里垂直居中，不再靠固定 86×15 的文字层顶对齐。
@MainActor
struct TimelineSkimmerLayoutTests {
    @Test func skimmerTimecodeIsCenteredInTextSizedPlate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caplo-skimmer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try ProjectStorage.create(in: root, name: "悬停")
        let document = try ProjectStorage.load(url)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: document))
        await model.open()
        defer { model.close() }
        let viewport = TimelineViewport()
        let view = TimelineViewportView(model: model, viewport: viewport)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 300)
        window.contentView = view
        view.update(edit: model.edit, analysis: model.analysis, selection: [], primary: nil, focus: nil, zoom: 0, fit: 0)
        view.layoutSubtreeIfNeeded()
        model.skim(0)
        view.refreshSkimmerForTesting()
        let (plate, text) = try #require(view.skimmerFramesForTesting())
        #expect(!plate.isEmpty && !text.isEmpty)
        // 文字层在底板内部、左右各留 6 点，垂直居中误差不超过 1 点。
        #expect(abs(text.minX - (plate.minX + 6)) < 0.5 && abs(plate.maxX - (text.maxX + 6)) < 0.5)
        #expect(abs(text.midY - plate.midY) <= 1)
        #expect(plate.height == 16 && text.height < plate.height)
        if let out = ProcessInfo.processInfo.environment["CAPLO_LAYOUT_PNG"], let layer = view.layer {
            let scale: CGFloat = 2
            let rect = plate.insetBy(dx: -30, dy: -12)
            if let context = CGContext(data: nil, width: Int(rect.width * scale), height: Int(rect.height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: 0, y: rect.height); context.scaleBy(x: 1, y: -1)
                context.translateBy(x: -rect.minX, y: -rect.minY)
                layer.render(in: context)
                if let image = context.makeImage() {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
            }
        }
    }
}

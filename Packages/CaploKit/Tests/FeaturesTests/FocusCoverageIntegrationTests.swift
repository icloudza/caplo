import Foundation
import AVFoundation
import EditingCore
import ProjectKit
import ExportKit
import Testing

extension WindowLifecycleTests {
    /// 模拟旧版本保存的越界镜头，验证打开规范化以及实际预览 / 导出都以媒体结尾收束。
    @Test func legacyFocusTailIsNormalizedBeforeLoadingAndCannotExtendPreviewOrExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root)
        let document = try ProjectStorage.load(url)
        var legacy = VideoEdit(duration: 4)
        legacy.prepareLayerEditing(camera: false, system: false, microphone: false)
        var focus = FocusSegment(start: 1, duration: 6, x: 0.5, y: 0.5)
        focus.timelineStart = 1; focus.targetClipID = legacy.clips[0].id
        legacy.focuses = [focus]
        // 直接写入旧文件，以便覆盖 load 在校验之前修正越界的迁移入口。
        try JSONEncoder().encode(legacy).write(to: url.appendingPathComponent("edits.json"))
        let loaded = try EditStorage.load(in: url, document: document)
        #expect(loaded.duration == 4)
        #expect(loaded.focuses.first?.timelineStart == 1 && loaded.focuses.first?.duration == 3)
        try loaded.validate(sourceDuration: document.duration)

        let preview = try await ProjectMedia.playerItem(url: url, document: document, levels: loaded.audio, edit: loaded)
        let previewDuration = try await preview.asset.load(.duration).seconds
        let instruction = try #require(preview.videoComposition?.instructions.first)
        #expect(abs(previewDuration - 4) < 0.001)
        #expect(abs(instruction.timeRange.end.seconds - 4) < 0.001)
        let output = root.appendingPathComponent("bounded-focus.mp4")
        try await ProjectMedia.export(url: url, document: document, levels: loaded.audio,
                                      destination: output, edit: loaded, longEdge: 320) { _ in }
        let exportedDuration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(exportedDuration - previewDuration) < 1.0 / 30 + 0.001)
        #expect(abs(exportedDuration - loaded.duration) < 1.0 / 30 + 0.001)
    }
}

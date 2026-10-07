import Foundation
import AVFoundation
import CoreImage
import Testing
import ProjectKit
import EditingCore
import ExportKit

extension WindowLifecycleTests {
    /// 真正导出含前导空白、重叠覆盖、末帧保持和独立声音的工程，逐点比对静帧；声音默认跟随画面，分离后才独立。
    @Test func layeredExportMatchesPreviewAcrossGapsOverlapAndHold() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root, audio: true)
        let document = try ProjectStorage.load(url)
        var edit = VideoEdit(duration: 4)
        edit.prepareLayerEditing(camera: false, system: false, microphone: true)
        let first = edit.clips[0].id
        // 默认声音跟随画面：不拆出单独的麦克风轨，画面挪到 1 秒处，声音跟着从 1 秒响到素材末尾（末帧保持区没有声音）。
        #expect(edit.microphoneClips == nil, "声音默认被拆成了单独的轨")
        var linked = edit
        linked.dragMedia(.screen, id: first, edge: .body, delta: 1, sourceDuration: 4)
        linked.dragMedia(.screen, id: first, edge: .trailing, delta: 2, sourceDuration: 4)
        #expect(linked.microphoneClips == nil, "拖画面把声音拆了出来")
        let (followed, _) = try await ProjectMedia.compose(url: url, document: document, levels: linked.audio, edit: linked)
        let followedRanges = try #require(followed.tracks(withMediaType: .audio).first).segments.filter { !$0.isEmpty }.map { $0.timeMapping.target }
        #expect(followedRanges.first?.start.seconds == 1 && followedRanges.last?.end.seconds == 5, "声音没有跟着画面走")
        // 分离声音之后才是独立的一份，可以单独拖动。
        edit.detachAudio()
        edit.dragMedia(.screen, id: first, edge: .body, delta: 1, sourceDuration: 4)
        edit.dragMedia(.screen, id: first, edge: .trailing, delta: 2, sourceDuration: 4)
        var top = VideoClip(sourceStart: 2, duration: 1); top.timelineStart = 1.5
        edit.clips.append(top); edit.moveLayer(top.id, before: first)
        let audioID = try #require(edit.microphoneClips?.first?.id)
        edit.dragMedia(.microphone, id: audioID, edge: .body, delta: 2, sourceDuration: 4)
        try edit.validate(sourceDuration: 4)
        try EditStorage.save(edit, in: url, document: document)
        #expect(try EditStorage.load(in: url, document: document) == edit)
        let (composition, _) = try await ProjectMedia.compose(url: url, document: document, levels: edit.audio, edit: edit)
        #expect(abs(composition.duration.seconds - 7) < 0.001)
        let audio = try #require(composition.tracks(withMediaType: .audio).first)
        let ranges = audio.segments.filter { !$0.isEmpty }.map { $0.timeMapping.target }
        #expect(ranges.first?.start.seconds == 2)
        #expect(ranges.last?.end.seconds == 6)
        let output = root.appendingPathComponent("layers.mp4")
        try await ProjectMedia.export(url: url, document: document, levels: edit.audio, destination: output, edit: edit) { _ in }
        let asset = AVURLAsset(url: output)
        #expect(abs(try await asset.load(.duration).seconds - 7) < 0.04)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let renderer = EditorPreviewRenderer()
        let context = CIContext()
        func center(_ image: CGImage) -> [UInt8] {
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(CIImage(cgImage: image), toBitmap: &pixel, rowBytes: 4,
                bounds: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return pixel
        }
        for time in [0.5, 1.2, 1.8, 2.7, 4.5, 6.5] {
            let preview = try await renderer.render(url: url, document: document, edit: edit, time: time)
            let exported = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let lhs = center(preview), rhs = center(exported)
            for channel in 0..<3 { #expect(abs(Int(lhs[channel]) - Int(rhs[channel])) < 18) }
            if time == 1.2 || time == 2.7 { #expect(lhs[0] > 180 && lhs[2] < 60) }
            if time == 1.8 || time == 6.5 { #expect(lhs[2] > 180 && lhs[0] < 60) }
        }
        await renderer.close()
    }

}

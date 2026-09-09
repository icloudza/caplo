import AVFoundation
import CoreImage
import Testing
import ProjectKit
import ExportKit
import EditingCore
@testable import CaptureKit

/// 用真实编码素材验证复用解码器、缓存淘汰与合成一致性，不以耗时阈值作为易波动的单元测试条件。
@Test @MainActor func previewCacheKeepsPixelsAndBoundsMemory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "静帧缓存测试")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: false, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) { writer.ingest(try makeFrame(at: CMTime(seconds: 10, preferredTimescale: 600)), role: .screen) }
    try await writer.finish(at: CMTime(seconds: 13, preferredTimescale: 600))
    let document = try ProjectStorage.load(url)
    var edit = VideoEdit(duration: document.duration)
    let renderer = EditorPreviewRenderer()
    for padding in [20.0, 40, 60] {
        edit.layout.padding = padding
        let actual = try await renderer.render(url: url, document: document, edit: edit, time: 0.5)
        let expected = try await ProjectMedia.poster(url: url, document: document, edit: edit, time: 0.5)
        let context = CIContext()
        let size = actual.width * actual.height * 4
        var lhs = [UInt8](repeating: 0, count: size), rhs = lhs
        let bounds = CGRect(x: 0, y: 0, width: actual.width, height: actual.height)
        let color = CGColorSpace(name: CGColorSpace.sRGB)
        context.render(CIImage(cgImage: actual), toBitmap: &lhs, rowBytes: actual.width * 4, bounds: bounds, format: .RGBA8, colorSpace: color)
        context.render(CIImage(cgImage: expected), toBitmap: &rhs, rowBytes: actual.width * 4, bounds: bounds, format: .RGBA8, colorSpace: color)
        #expect(lhs == rhs)
    }
    #expect(await renderer.decodedFrameCount == 1)
    for time in [0.6, 0.7, 0.8, 0.9, 0.5] { _ = try await renderer.render(url: url, document: document, edit: edit, time: time) }
    #expect(await renderer.decodedFrameCount == 6) // 第五个新时间挤出旧缓存，重访时必须重新解码。
    #expect(await renderer.generatorCount == 1)
    await renderer.close()
    await #expect(throws: CancellationError.self) { try await renderer.render(url: url, document: document, edit: edit, time: 0.5) }
}

@Test @MainActor func presentationUpdatesKeepCompositionAndCorrectAudioRoles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "播放项复用测试")
    // 只存在麦克风，验证它不会因为是第一条音轨而误用系统声音增益。
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: true, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) {
        writer.ingest(try makeFrame(at: CMTime(seconds: 10, preferredTimescale: 600)), role: .screen)
        writer.ingest(try makeAudio(at: CMTime(seconds: 10, preferredTimescale: 600), duration: 1, channels: 1), role: .microphone)
    }
    try await writer.finish(at: CMTime(seconds: 11, preferredTimescale: 600))
    let document = try ProjectStorage.load(url)
    var edit = VideoEdit(duration: document.duration)
    // 素材重复引用验证 AVAsset 生命周期；丢失持有关系会在第二次插入时报 -12780。
    edit.clips = (0..<300).map { _ in VideoClip(sourceStart: 0, duration: 0.1) }
    let item = try await ProjectMedia.playerItem(url: url, document: document, levels: edit.audio, edit: edit)
    let originalAsset = item.asset
    #expect(abs(try await originalAsset.load(.duration).seconds - 30) < 0.01)
    var changed = edit
    changed.layout.ratio = .portrait; changed.audio.microphone = 0.25; changed.audio.system = 0
    try ProjectMedia.updatePresentation(item: item, previous: edit, edit: changed)
    #expect(item.asset === originalAsset)
    #expect(item.videoComposition?.renderSize == CGSize(width: 1080, height: 1920))
    let parameter = try #require(item.audioMix?.inputParameters.first)
    var start: Float = 0, end: Float = 0, range = CMTimeRange.zero
    #expect(parameter.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range))
    #expect(abs(start - 0.25) < 0.001)
    changed.clips.removeLast()
    #expect(throws: ProjectError.self) { try ProjectMedia.updatePresentation(item: item, previous: edit, edit: changed) }
}

/// 时间指针拖到最末尾要看到最后一帧而不是背景：离线静帧在素材末尾一点点之外取最后一帧；播放 / 导出的合成把最后一帧拉长补到片段末尾。
@Test @MainActor func theVeryEndShowsTheLastFrameNotTheBackground() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "末帧")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: false, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) { writer.ingest(try makeFrame(at: CMTime(seconds: 10, preferredTimescale: 600)), role: .screen) }
    try await writer.finish(at: CMTime(seconds: 13, preferredTimescale: 600))
    var document = try ProjectStorage.load(url)
    // 写入器会把最后一帧补到停止时刻，这里把工程记的时长再拉长半秒，复现"素材比工程记的时长短"的情况。
    document.segments[0].duration += 0.5
    let mediaPath = try #require(document.segments.first?.files[.screen])
    let mediaTrack = try #require(try await AVURLAsset(url: ProjectStorage.mediaURL(mediaPath, in: url)).loadTracks(withMediaType: .video).first)
    let mediaRange = try await mediaTrack.load(.timeRange)
    #expect(mediaRange.end.seconds < document.duration, "素材 \(mediaRange.end.seconds) 应短于工程 \(document.duration)")
    var edit = VideoEdit(duration: document.duration)
    edit.layout.padding = 0; edit.layout.cornerRadius = 0; edit.layout.shadow = false
    let renderer = EditorPreviewRenderer()
    let middle = try await renderer.render(url: url, document: document, edit: edit, time: 1)
    let end = try await renderer.render(url: url, document: document, edit: edit, time: document.duration)
    let context = CIContext(), bounds = CGRect(x: 0, y: 0, width: middle.width, height: middle.height)
    func bytes(_ image: CGImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        context.render(CIImage(cgImage: image), toBitmap: &buffer, rowBytes: image.width * 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }
    #expect(bytes(end) == bytes(middle), "末尾与中段是同一帧画面，不是背景")
    await renderer.close()
    let item = try await ProjectMedia.playerItem(url: url, document: document, levels: edit.audio, edit: edit)
    let track = try #require(try await item.asset.loadTracks(withMediaType: .video).first)
    let range = try await track.load(.timeRange)
    #expect(abs(range.end.seconds - document.duration) < 0.002, "合成的画面轨道补到工程末尾：\(range.end.seconds) vs \(document.duration)")
}

/// 两个手动镜头（1.8× 与靠近末尾的 3.0×）走播放 / 导出的合成：播放项能建、合成帧能渲染、尺寸正常。
@Test @MainActor func compositionRendersWithStackedFocusSegments() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "多镜头")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: true, microphone: false, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) {
        writer.ingest(try makeFrame(at: CMTime(seconds: 10, preferredTimescale: 600)), role: .screen)
        writer.ingest(try makeAudio(at: CMTime(seconds: 10, preferredTimescale: 600), duration: 1, channels: 2), role: .systemAudio)
    }
    try await writer.finish(at: CMTime(seconds: 24.5, preferredTimescale: 600))
    let document = try ProjectStorage.load(url)
    var edit = VideoEdit(duration: document.duration)
    edit.prepareLayerEditing(camera: false, system: true, microphone: false)
    edit.focuses = [FocusSegment(start: 2, duration: 8, x: 0.4, y: 0.4, scale: 1.8), FocusSegment(start: 11, duration: 3.4, x: 0.6, y: 0.6, scale: 3)]
    edit.automaticFocus = true
    try edit.validate(sourceDuration: document.duration)
    let item = try await ProjectMedia.playerItem(url: url, document: document, levels: edit.audio, edit: edit)
    let size = try #require(item.videoComposition?.renderSize)
    #expect(size.width > 0 && size.height > 0 && size.width.isFinite)
    for time in [1.0, 5.0, 12.5, 14.0] {
        let poster = try await ProjectMedia.poster(url: url, document: document, edit: edit, time: time)
        #expect(poster.width > 0 && poster.height > 0, "\(time)")
    }
}

/// 播放项不只是能建：真正交给 AVPlayer 播 1 秒，状态要变成就绪、时间要往前走（合成有问题时播放器会静默停住）。
@Test @MainActor func playerActuallyAdvancesOnTheComposition() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "真播")
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: true, microphone: false, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) {
        writer.ingest(try makeFrame(at: CMTime(seconds: 10, preferredTimescale: 600)), role: .screen)
        writer.ingest(try makeAudio(at: CMTime(seconds: 10, preferredTimescale: 600), duration: 1, channels: 2), role: .systemAudio)
    }
    try await writer.finish(at: CMTime(seconds: 24.5, preferredTimescale: 600))
    var document = try ProjectStorage.load(url)
    document.segments[0].duration += 0.3   // 素材比工程记的时长短一点：末帧拉长那条路径也要能播
    var edit = VideoEdit(duration: document.duration)
    edit.prepareLayerEditing(camera: false, system: true, microphone: false)
    edit.focuses = [FocusSegment(start: 2, duration: 8, x: 0.4, y: 0.4, scale: 1.8), FocusSegment(start: 11, duration: 3.4, x: 0.6, y: 0.6, scale: 3)]
    let item = try await ProjectMedia.playerItem(url: url, document: document, levels: edit.audio, edit: edit)
    let player = AVPlayer(playerItem: item)
    player.isMuted = true
    player.play()
    for _ in 0..<40 where item.status != .failed && player.currentTime().seconds < 0.5 { try await Task.sleep(for: .milliseconds(100)) }
    #expect(item.status == .readyToPlay, "播放项状态 \(item.status.rawValue)：\(item.error?.localizedDescription ?? "")")
    #expect(player.currentTime().seconds >= 0.5, "播放 4 秒内时间没有前进：\(player.currentTime().seconds)，等待原因 \(player.reasonForWaitingToPlay?.rawValue ?? "无")")
    player.pause()
}

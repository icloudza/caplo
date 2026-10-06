import AVFoundation
import ProjectKit
import ImageIO

@_exported import EditingCore
import RenderKit
import CoreImage

/// 回放与导出共用独立图层解析结果；遮挡、空白和末帧保持遵循编辑时间。
@MainActor
public enum ProjectMedia {
    public static func compose(url: URL, document: ProjectDocument, levels: AudioLevels, edit: VideoEdit? = nil) async throws -> (AVMutableComposition, AVMutableAudioMix) {
        if let edit { try edit.validate(sourceDuration: document.duration) }
        guard !document.segments.isEmpty else { throw ProjectError.invalid("工程没有可播放的片段。") }
        let composition = AVMutableComposition()
        var audioGroups: [MediaRole: [(UUID?, AVMutableCompositionTrack)]] = [:]
        // 分段编码可能产生不同的 H.264 参数集；按完整格式复用解码轨道，避免切换时解码失败。
        var videoGroups: [MediaRole: [(formats: [CMFormatDescription], track: AVMutableCompositionTrack)]] = [:]
        // 同一素材可能被剪成数百个片段；轨道与时间范围只加载一次，后续插入共享元数据。
        var sources: [String: (asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange, formats: [CMFormatDescription])] = [:]
        let segments = document.segments.sorted(by: { $0.id < $1.id })
        let snapshot = edit ?? VideoEdit(duration: document.duration)
        let roleMap: [(MediaRole, TimelineMedia)] = [(.screen, .screen), (.camera, .camera), (.systemAudio, .system), (.microphone, .microphone)]
        for (role, logical) in roleMap {
          let separateAudio = !role.isVideo && (role == .systemAudio ? snapshot.systemClips != nil : snapshot.microphoneClips != nil)
          let media = separateAudio ? snapshot.mediaClips(logical) : snapshot.resolvedMedia(logical)
          for original in media {
            // 普通区间保持原速；超出源结尾的视频使用末帧的单帧区间扩展，音频不补内容。
            var jobs: [(VideoClip, Double?)] = []
            let playable = original.playableDuration
            if playable > 0.0001 { var live = original; live.duration = playable; jobs.append((live, nil)) }
            if role.isVideo, original.duration - playable > 0.0001 {
                var hold = original
                let frame = 1 / max(24, document.frameRate)
                hold.sourceStart = max(0, original.sourceStart + playable - frame)
                hold.timelineStart = (original.timelineStart ?? 0) + playable
                hold.duration = frame
                jobs.append((hold, original.duration - playable))
            }
          for (clip, heldDuration) in jobs {
            let cursor = clip.timelineStart ?? 0
            var segmentStart = 0.0
            for segment in segments {
                defer { segmentStart += segment.duration }
                let lower = max(clip.sourceStart, segmentStart)
                let upper = min(clip.sourceStart + clip.duration, segmentStart + segment.duration)
                guard upper > lower else { continue }
                let requested = CMTimeRange(start: CMTime(seconds: lower - segmentStart, preferredTimescale: 48_000), duration: CMTime(seconds: upper - lower, preferredTimescale: 48_000))
                do {
                    try Task.checkCancellation()
                    guard let path = mediaPath(for: role, in: segment, levels: levels, project: url) else { continue }
                    let offset = CMTime(seconds: segment.offset(for: role), preferredTimescale: 48_000)
                    let localRequest = CMTimeRange(start: requested.start - offset, duration: requested.duration)
                    let mediaType: AVMediaType = role.isVideo ? .video : .audio
                    let key = role.rawValue + ":" + path
                    let source: AVAssetTrack, sourceRange: CMTimeRange, formats: [CMFormatDescription]
                    if let cached = sources[key] {
                        source = cached.track; sourceRange = cached.range; formats = cached.formats
                    } else {
                        let asset = AVURLAsset(url: try ProjectStorage.mediaURL(path, in: url))
                        guard let loaded = try await asset.loadTracks(withMediaType: mediaType).first else {
                            throw ProjectError.invalid("素材缺少预期轨道：\(path)")
                        }
                        source = loaded; sourceRange = try await loaded.load(.timeRange)
                        formats = role.isVideo ? try await loaded.load(.formatDescriptions) : []
                        // 轨道对象不能替代素材生命周期；拼接完成前同时持有其所属 AVAsset。
                        sources[key] = (asset, source, sourceRange, formats)
                    }
                    let range = CMTimeRangeGetIntersection(sourceRange, otherRange: localRequest)
                    if range.duration > .zero {
                        let destination: AVMutableCompositionTrack
                        if role.isVideo {
                            let groups = videoGroups[role] ?? []
                            if let matching = groups.first(where: { group in
                                group.formats.count == formats.count && zip(group.formats, formats).allSatisfy {
                                    CMFormatDescriptionEqual($0.0, otherFormatDescription: $0.1)
                                }
                            }) {
                                destination = matching.track
                            } else {
                                // 首条屏幕 / 摄像头仍为 1 / 4；额外屏幕使用奇数 5 起，摄像头使用偶数 6 起。
                                let identifier = groups.isEmpty ? trackID(for: role) : CMPersistentTrackID((role == .screen ? 3 : 4) + groups.count * 2)
                                guard let created = composition.addMutableTrack(withMediaType: .video, preferredTrackID: identifier) else {
                                    throw ProjectError.invalid("无法创建视频解码轨道。")
                                }
                                videoGroups[role, default: []].append((formats, created))
                                destination = created
                            }
                        } else {
                            let key: UUID? = separateAudio ? original.id : nil
                            if let matching = audioGroups[role]?.first(where: { $0.0 == key }) { destination = matching.1 }
                            else {
                                let count = separateAudio ? (media.firstIndex { $0.id == original.id } ?? 0) : 0
                                let identifier = count == 0 ? trackID(for: role) : CMPersistentTrackID(100_000 + count * 2 + (role == .systemAudio ? 0 : 1))
                                guard let created = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: identifier) else { throw ProjectError.invalid("无法创建声音轨道。") }
                                audioGroups[role, default: []].append((key, created)); destination = created
                            }
                        }
                        // 所有素材使用同一裁剪交集；晚到的声音和摄像头保留各自偏移。
                        let position = CMTime(seconds: cursor + lower - clip.sourceStart, preferredTimescale: 48_000) + range.start - localRequest.start
                        try destination.insertTimeRange(range, of: source, at: position)
                        if let heldDuration {
                            destination.scaleTimeRange(CMTimeRange(start: position, duration: range.duration), toDuration: CMTime(seconds: heldDuration, preferredTimescale: 48_000))
                        } else if role.isVideo, CMTimeCompare(localRequest.end, range.end) > 0 {
                            // 素材比工程记的时长短一点（写入器按停止时刻记时长，最后一帧的显示时长够不到末尾）：
                            // 把最后一帧拉长补到片段末尾，最多补 1 秒；再长就是素材真的提前结束，那段不画。
                            let shortfall = CMTimeMinimum(CMTimeSubtract(localRequest.end, range.end), CMTime(seconds: 1, preferredTimescale: 48_000))
                            let hold = CMTimeMinimum(range.duration, CMTime(seconds: 1 / max(24, document.frameRate), preferredTimescale: 48_000))
                            if shortfall > .zero, hold > .zero {
                                destination.scaleTimeRange(CMTimeRange(start: position + range.duration - hold, duration: hold), toDuration: hold + shortfall)
                            }
                        }
                    }
                }
            }
          }
          }
        }
        // AVFoundation 不支持完全空的视频轨道导出；用原素材单帧提供时钟，合成器按逻辑空白只画背景。
        if composition.track(withTrackID: 1) == nil, snapshot.duration > 0,
           let path = segments.compactMap({ $0.files[.screen] }).first {
            let asset = AVURLAsset(url: try ProjectStorage.mediaURL(path, in: url))
            if let source = try await asset.loadTracks(withMediaType: .video).first,
               let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1) {
                let sourceRange = try await source.load(.timeRange)
                let frame = CMTimeRange(start: sourceRange.start, duration: min(sourceRange.duration, CMTime(seconds: 1 / max(24, document.frameRate), preferredTimescale: 48_000)))
                try track.insertTimeRange(frame, of: source, at: .zero)
                track.scaleTimeRange(CMTimeRange(start: .zero, duration: frame.duration), toDuration: CMTime(seconds: snapshot.duration, preferredTimescale: 48_000))
            }
        }
        if composition.duration.seconds < snapshot.duration {
            composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration, duration: CMTime(seconds: snapshot.duration - composition.duration.seconds, preferredTimescale: 48_000)))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [MediaRole.systemAudio, .microphone].flatMap { role in
            (audioGroups[role] ?? []).map { id, track in
                let parameter = AVMutableAudioMixInputParameters(track: track)
                let audioTrack: AudioTrack = role == .systemAudio ? .system : .microphone
                let logical: TimelineMedia = role == .systemAudio ? .system : .microphone
                let values = id == nil ? snapshot.resolvedMedia(logical) : snapshot.mediaClips(logical).filter { $0.id == id }
                for clip in values {
                    parameter.setVolume(levels.effectiveGain(for: audioTrack) * clip.gain(for: audioTrack), at: CMTime(seconds: clip.timelineStart ?? 0, preferredTimescale: 48_000))
                }
                return parameter
            }
        }
        return (composition, mix)
    }

    /// `pointers` 允许调用方复用已解析的指针事件（编辑会话内事件不变），避免每次重建播放项都在主线程解一遍 JSON。
    /// 麦克风在语音处理打开且该片段的产物已生成时换用产物；其余素材按录制文件。
    nonisolated static func mediaPath(for role: MediaRole, in segment: SegmentRecord, levels: AudioLevels, project: URL) -> String? {
        guard role == .microphone, levels.voiceProcessing, let processed = VoiceProcessor.processedPath(for: segment),
              let url = try? ProjectStorage.mediaURL(processed, in: project), FileManager.default.fileExists(atPath: url.path) else { return segment.files[role] }
        return processed
    }

    public static func playerItem(url: URL, document: ProjectDocument, levels: AudioLevels, edit: VideoEdit? = nil, pointers: PointerTimeline? = nil) async throws -> AVPlayerItem {
        let (composition, mix) = try await compose(url: url, document: document, levels: levels, edit: edit)
        let item = AVPlayerItem(asset: composition)
        item.audioMix = mix
        if let edit { item.videoComposition = try videoComposition(composition: composition, edit: edit, longEdge: 1920, pointers: pointers ?? loadPointers(url: url, document: document), backgroundImage: backgroundImage(for: edit.layout, in: url), frameRate: document.frameRate) }
        return item
    }

    private static func trackID(for role: MediaRole) -> CMPersistentTrackID {
        switch role { case .screen: 1; case .systemAudio: 2; case .microphone: 3; case .camera: 4 }
    }

    /// 画布、镜头和音量不改变素材拼接，直接更新同一个播放项，保留解码与缓冲状态。
    public static func updatePresentation(item: AVPlayerItem, previous: VideoEdit, edit: VideoEdit, url: URL? = nil) throws {
        guard previous.hasSameMedia(as: edit), let composition = item.asset as? AVMutableComposition else {
            throw ProjectError.invalid("片段已变化，需要重新构建播放时间线。")
        }
        if edit.differsVisually(from: previous) {
            let existing = item.videoComposition?.instructions.first as? SceneInstruction
            let background = previous.layout.backgroundImage == edit.layout.backgroundImage ? existing?.backgroundImage : url.flatMap { backgroundImage(for: edit.layout, in: $0) }
            let rate = item.videoComposition.map { 1 / $0.frameDuration.seconds } ?? 30
            item.videoComposition = try videoComposition(composition: composition, edit: edit, longEdge: 1920, pointers: existing?.pointers ?? PointerTimeline(events: []), backgroundImage: background, frameRate: rate.isFinite && rate > 0 ? rate : 30, reusing: existing)
        }
        if previous.audio != edit.audio {
            let mix = AVMutableAudioMix()
            mix.inputParameters = [MediaRole.systemAudio, .microphone].flatMap { role -> [AVMutableAudioMixInputParameters] in
                let logical: TimelineMedia = role == .systemAudio ? .system : .microphone
                let audio: AudioTrack = role == .systemAudio ? .system : .microphone
                let independent = role == .systemAudio ? edit.systemClips != nil : edit.microphoneClips != nil
                let values = independent ? edit.mediaClips(logical) : edit.resolvedMedia(logical)
                let tracks = composition.tracks.filter { $0.mediaType == .audio && ($0.trackID == trackID(for: role) || ($0.trackID >= 100_002 && $0.trackID % 2 == (role == .systemAudio ? 0 : 1))) }.sorted { $0.trackID < $1.trackID }
                return tracks.map { track in
                    let parameter = AVMutableAudioMixInputParameters(track: track)
                    let clipIndex = track.trackID < 100_002 ? 0 : Int((track.trackID - 100_000) / 2)
                    let clips = independent ? (values.indices.contains(clipIndex) ? [values[clipIndex]] : []) : values
                    for clip in clips { parameter.setVolume(edit.audio.effectiveGain(for: audio) * clip.gain(for: audio), at: CMTime(seconds: clip.timelineStart ?? 0, preferredTimescale: 48_000)) }
                    return parameter
                }
            }
            item.audioMix = mix
        }
    }

    /// 项目列表的封面：取第一段素材的首帧，并盖上那一刻生效的遮罩。
    /// 读不出遮罩就抛错而不是给一张没打码的图——封面上印着密钥比没有封面糟糕得多。
    public static func thumbnail(url: URL, document: ProjectDocument) async throws -> CGImage {
        guard let path = document.segments.first?.files[.screen] else { throw ProjectError.invalid("暂无缩略图。") }
        let masks = try EditStorage.maskList(in: url)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: try ProjectStorage.mediaURL(path, in: url)))
        generator.maximumSize = CGSize(width: 640, height: 400)
        generator.appliesPreferredTrackTransform = true
        let frame = try await generator.image(at: .zero).image
        var edit = VideoEdit(duration: max(0.001, document.duration)); edit.maskList = masks
        let states = edit.sourceMasks(atSource: 0)
        guard !states.isEmpty else { return frame }
        let source = CIImage(cgImage: frame)
        guard let masked = CIContext().createCGImage(MaskRenderer.apply(states, to: source), from: source.extent) else {
            throw ProjectError.invalid("无法生成已打码的缩略图。")
        }
        return masked
    }

    /// 暂停和拖动时输出清晰静帧，使用同一个场景渲染器；不依赖原生视频图层的离屏可见性。
    public static func poster(url: URL, document: ProjectDocument, edit: VideoEdit, time: Double) async throws -> CGImage {
        let renderer = EditorPreviewRenderer()
        do {
            let image = try await renderer.render(url: url, document: document, edit: edit, time: time)
            await renderer.close()
            return image
        } catch {
            await renderer.close()
            throw error
        }
    }

    nonisolated static func pointerTimeline(url: URL, document: ProjectDocument) throws -> PointerTimeline {
        let events = try EditStorage.events(in: url, document: document)
        return PointerTimeline(events: events, cursorEmbedded: document.capture?.cursorEmbedded != false,
                               capturedCursors: CursorStorage.load(ids: Set(events.compactMap(\.cursorAssetID)), in: url))
    }

    nonisolated public static func loadPointers(url: URL, document: ProjectDocument) throws -> PointerTimeline {
        try ProjectMedia.pointerTimeline(url: url, document: document)
    }

    /// 读取工程内的自定义背景图；文件缺失或无法解码时回退到色板背景。
    /// 背景图只解码一次成位图（最长边不超过 3840，与导出上限一致）再交给 Core Image：
    /// `CIImage(contentsOf:)` 是惰性的，布局每变一步重算背景都会把原文件（5K WebP 软件解码）重新解一遍，拖留白时逐步卡顿、内存暴涨。
    nonisolated public static func backgroundImage(for layout: CanvasLayout, in url: URL) -> CIImage? {
        guard let path = layout.backgroundImage, let file = try? ProjectStorage.backgroundURL(path, in: url) else { return nil }
        return decodedBackground(at: file)
    }
    nonisolated static let backgroundMaximumEdge = 3840
    nonisolated static func decodedBackground(at file: URL) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        guard let image = ImageDownsampler.image(from: source, maximumPixelSize: backgroundMaximumEdge) else { return CIImage(contentsOf: file) }
        return CIImage(cgImage: image)
    }

    private static func videoComposition(composition: AVMutableComposition, edit: VideoEdit, longEdge: Int, pointers: PointerTimeline, backgroundImage: CIImage? = nil, frameRate: Double = 30, reusing previous: SceneInstruction? = nil) throws -> AVVideoComposition {
        guard let track = composition.track(withTrackID: trackID(for: .screen)), edit.duration > 0 else { throw ProjectError.invalid("时间线为空，请先恢复一个片段。") }
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = VideoCompositor.self
        let routes = composition.tracks.filter { $0.mediaType == .video }.flatMap { source in
            source.segments.filter { !$0.isEmpty }.map { VideoTrackRange(trackID: source.trackID, range: $0.timeMapping.target) }
        }
        let screens = routes.filter { $0.trackID == 1 || ($0.trackID >= 5 && $0.trackID % 2 == 1) }
        let cameras = edit.camera?.enabled == true ? routes.filter { $0.trackID >= 4 && $0.trackID % 2 == 0 } : []
        video.instructions = [SceneInstruction(trackID: track.trackID, edit: edit, screenRoutes: screens, cameraRoutes: cameras, pointers: pointers, backgroundImage: backgroundImage, reusing: previous)]
        // 短边固定 1080 / 2160，长边按比例伸展：方形以此为边长，横竖屏保持标准 1080p / UHD 尺寸，避免预设静默缩小超大方形画布。
        let size = edit.layout.ratio.outputSize(shortEdge: longEdge == 3840 ? 2160 : 1080)
        video.renderSize = CGSize(width: size.width, height: size.height)
        // 输出帧率与录制帧率一致（旧工程 30）；60 fps 素材不再被折半。
        video.frameDuration = CMTime(value: 1, timescale: Int32(max(24, min(120, frameRate.rounded()))))
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return video
    }

    /// 固定工程快照导出；取消仅清理本次临时文件，不触碰用户原有目标或原素材。
    public static func export(url: URL, document: ProjectDocument, levels: AudioLevels, destination: URL, edit: VideoEdit? = nil, longEdge: Int = 1920,
                              progress: @escaping @MainActor (Double) -> Void) async throws {
        let (composition, mix) = try await compose(url: url, document: document, levels: levels, edit: edit)
        // 码率与帧率自己定（见 ExportEncoder）：系统预设在 4K 上只给约 10 Mbps 且降到 30 fps。
        let rate = ExportEncoder.frameRate(recorded: document.frameRate, longEdge: longEdge)
        let video = try edit.map { try videoComposition(composition: composition, edit: $0, longEdge: longEdge, pointers: loadPointers(url: url, document: document), backgroundImage: backgroundImage(for: $0.layout, in: url), frameRate: rate) }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".caplo-export-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await ExportEncoder.encode(asset: composition, videoComposition: video, audioMix: mix, destination: temporary) { value in
            Task { @MainActor in progress(value) }
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        progress(1)
    }
}

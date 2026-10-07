import Foundation
import CoreGraphics
import ProjectKit
import EditingCore
import ExportKit

/// 固定合成素材和操作序列用于比较改动前后耗时，不读取用户工程或采集设备输入。
@MainActor
enum EditorBenchmark {
    static func run(output: URL) async throws {
        let url = try await PreviewFixture.create()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try ProjectStorage.load(url)
        var edit = VideoEdit(duration: document.duration)
        var results: [String: Double] = [:]
        let clock = ContinuousClock()
        func seconds(_ elapsed: Duration) -> Double {
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        let renderer = EditorPreviewRenderer()
        var start = clock.now
        for index in 0..<20 {
            edit.layout.padding = Double(20 + index)
            do { _ = try await renderer.render(url: url, document: document, edit: edit, time: 2) }
            catch { throw BenchmarkError.frame("layout \(index)", error) }
        }
        results["layout20Seconds"] = seconds(start.duration(to: clock.now))
        start = clock.now
        for index in 0..<20 {
            do { _ = try await renderer.render(url: url, document: document, edit: edit, time: Double(index) * 0.4) }
            catch { throw BenchmarkError.frame("scrub \(index)", error) }
        }
        results["scrub20Seconds"] = seconds(start.duration(to: clock.now))
        results["decodedFrames"] = Double(await renderer.decodedFrameCount)
        results["decoderCreations"] = Double(await renderer.generatorCount)
        await renderer.close()
        edit.clips = (0..<300).map { VideoClip(sourceStart: Double($0 % 100) / 10, duration: 0.1) }
        start = clock.now
        _ = try await ProjectMedia.compose(url: url, document: document, levels: edit.audio, edit: edit)
        results["composition300ClipsSeconds"] = seconds(start.duration(to: clock.now))
        try largeProject(into: &results)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(results)
        try data.write(to: output.appendingPathComponent("editor-performance.json"), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
    }
    /// 大型工程的保存链路：两小时录制、60 Hz 指针、约 1400 次点击生成的自动镜头，300 处分割、2400 条字幕、
    /// 100 段文字、50 个遮罩。分别量主线程每次提交的开销（比较、整理、校验）与后台编码、写盘、压缩的耗时和体积。
    private static func largeProject(into results: inout [String: Double]) throws {
        let duration = 7200.0
        let clock = ContinuousClock()
        func milliseconds(_ body: () throws -> Void) rethrows -> Double {
            let start = clock.now; try body(); let elapsed = start.duration(to: clock.now)
            return (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) * 1000
        }
        // 指针：每 3–8 秒移向一个新目标并点一下，其余时间 60 Hz 静止采样（与录制器一致）。确定性伪随机，结果可比。
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func random() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        var events: [PointerSample] = []; events.reserveCapacity(Int(duration * 60) + 3000)
        var from = CGPoint(x: 0.5, y: 0.5), to = from, moveStart = 0.0, nextClick = 2.0
        for index in 0..<Int(duration * 60) {
            let time = Double(index) / 60
            if time >= nextClick {
                events.append(PointerSample(time: time, x: to.x, y: to.y, kind: .click))
                from = to; to = CGPoint(x: 0.1 + random() * 0.8, y: 0.1 + random() * 0.8); moveStart = time + 0.4
                nextClick = time + 3 + random() * 5
            }
            let progress = min(1, max(0, (time - moveStart) / 0.9)), eased = progress * progress * (3 - 2 * progress)
            events.append(PointerSample(time: time, x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased, kind: .move))
        }
        var edit = VideoEdit(duration: duration)
        results["large.autoFocusMs"] = milliseconds { edit.focuses = AutoFocus.generate(events: events, duration: duration) }
        results["large.focusSegments"] = Double(edit.focuses.count)
        results["large.focusKeyframes"] = Double(edit.focuses.reduce(0) { $0 + ($1.path?.count ?? 0) })
        edit.prepareLayerEditing(camera: false, system: true, microphone: true)
        for index in 1...300 { _ = edit.split(at: Double(index) * duration / 301 + 0.37) }
        edit.captions = (0..<2400).map { index in
            let start = Double(index) * 3
            let words = (0..<8).map { CaptionWord(start: start + Double($0) * 0.35, end: start + Double($0) * 0.35 + 0.3, text: "词语\($0)") }
            return CaptionCue(sourceStart: start, sourceEnd: start + 2.8, text: words.map(\.text).joined(separator: " "), words: words)
        }
        for index in 0..<100 {
            var text = TextPreset.lowerThird.segment(start: Double(index) * 70, duration: 3)
            text.text = "第 \(index + 1) 段说明"; text.timelineStart = Double(index) * 70
            edit.addText(text)
        }
        for index in 0..<50 { edit.addMask(MaskSegment(start: Double(index) * 140, duration: 5, x: 0.2, y: 0.2, width: 0.2, height: 0.1)) }
        edit.normalizeSchemaVersion()
        try edit.validate(sourceDuration: duration)
        results["large.clips"] = Double(edit.clips.count)
        // 主线程上的一次提交：拷贝旧值、改一个参数、比较、整理与校验（VideoEditorModel.finishChange 的同一串调用）。
        var commits: [Double] = []
        for index in 0..<20 {
            commits.append(try milliseconds {
                let previous = edit
                edit.layout.padding = Double(20 + index)
                guard edit != previous else { return }
                edit.constrainTimelineFocuses(); edit.normalizeTimelineRows(); edit.normalizeSchemaVersion()
                try edit.validate(sourceDuration: duration)
            })
        }
        results["large.commitMedianMs"] = commits.sorted()[commits.count / 2]
        // 后台：编码、原子写、读回解码；以及两种无损压缩的耗时与体积。
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("caplo-bench-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        results["large.editEncodeMs"] = try milliseconds { data = try encoder.encode(edit) }
        results["large.editBytes"] = Double(data.count)
        results["large.editWriteMs"] = try milliseconds { try data.write(to: directory.appendingPathComponent("edits.json"), options: .atomic) }
        results["large.editDecodeMs"] = try milliseconds { _ = try JSONDecoder().decode(VideoEdit.self, from: data) }
        for (name, algorithm) in [("lzfse", NSData.CompressionAlgorithm.lzfse), ("zlib", .zlib)] {
            var packed = Data()
            results["large.edit.\(name)Ms"] = try milliseconds { packed = try (data as NSData).compressed(using: algorithm) as Data }
            results["large.edit.\(name)Bytes"] = Double(packed.count)
            results["large.edit.\(name)DecompressMs"] = try milliseconds { _ = try (packed as NSData).decompressed(using: algorithm) }
        }
        var eventData = Data()
        results["large.eventsEncodeMs"] = try milliseconds { eventData = try JSONEncoder().encode(events) }
        results["large.eventsBytes"] = Double(eventData.count)
        results["large.eventsDecodeMs"] = try milliseconds { _ = try JSONDecoder().decode([PointerSample].self, from: eventData) }
        var packedEvents = Data()
        results["large.events.lzfseMs"] = try milliseconds { packedEvents = try (eventData as NSData).compressed(using: .lzfse) as Data }
        results["large.events.lzfseBytes"] = Double(packedEvents.count)
        results["large.events.lzfseDecompressMs"] = try milliseconds { _ = try (packedEvents as NSData).decompressed(using: .lzfse) }
    }

    private enum BenchmarkError: Error { case frame(String, any Error) }
}

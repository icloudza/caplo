import Foundation
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
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(results)
        try data.write(to: output.appendingPathComponent("editor-performance.json"), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
    }
    private enum BenchmarkError: Error { case frame(String, any Error) }
}

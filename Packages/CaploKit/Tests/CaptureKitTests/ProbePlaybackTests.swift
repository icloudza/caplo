import AVFoundation
import Testing
import ProjectKit
import ExportKit
import EditingCore
@testable import CaptureKit

/// 临时探针：用环境变量指定的真实工程建播放项并真播 3 秒，观察播放器是否前进。
@Test @MainActor func probeRealProjectPlayback() async throws {
    guard let path = ProcessInfo.processInfo.environment["CAPLO_PROBE_PROJECT"] else { return }
    let url = URL(fileURLWithPath: path)
    let document = try ProjectStorage.load(url)
    let edit = try EditStorage.load(in: url, document: document)
    print("PROBE 时长 \(document.duration) 片段 \(edit.clips.count) 镜头 \(edit.focuses.count) 布局 \(edit.layout.ratio.rawValue)")
    let item = try await ProjectMedia.playerItem(url: url, document: document, levels: edit.audio, edit: edit)
    print("PROBE 合成尺寸 \(item.videoComposition?.renderSize ?? .zero) 帧时长 \(item.videoComposition?.frameDuration.seconds ?? 0)")
    let player = AVPlayer(playerItem: item)
    await player.seek(to: CMTime(seconds: 20.3, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
    player.play()
    for tick in 0..<30 {
        try await Task.sleep(for: .milliseconds(100))
        if tick % 5 == 4 { print("PROBE t=\(tick / 10 + 1)s 时间 \(player.currentTime().seconds) 状态 \(item.status.rawValue) 控制 \(player.timeControlStatus.rawValue) 等待 \(player.reasonForWaitingToPlay?.rawValue ?? "无") 错误 \(item.error?.localizedDescription ?? "无")") }
    }
    print("PROBE 最终时间 \(player.currentTime().seconds)")
    player.pause()
}

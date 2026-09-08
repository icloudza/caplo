import AVFoundation
import AppKit
import Testing
import ProjectKit
import EditingCore
@testable import Features

extension WindowLifecycleTests {
    /// 红 / 蓝合成素材检验真实像素；只核对时间数值无法发现预览仍停在旧帧的问题。
    @Test func skimmingShowsLatestFrameAndRestoresPlayheadWithoutEditing() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root)
        let document = try ProjectStorage.load(url)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: document))
        defer { model.close() }
        await model.open()
        try await waitForSkimmer { !model.loading && model.player.currentItem?.status == .readyToPlay && model.canvas.frame != nil }
        model.seek(0.5)
        try await waitForSkimmer { abs(model.player.currentTime().seconds - 0.5) < 0.01 && model.canvas.snapshot().map(isRedFrame) == true }
        let item = model.player.currentItem, original = model.edit
        let selection = model.selectedClipIDs
        let saved = try EditStorage.load(in: url, document: document)
        #expect(!model.history.canUndo)

        for number in 0..<200 { model.skim(Double(number % 35) / 10) }
        model.skim(2.5)
        try await waitForSkimmer { abs(model.player.currentTime().seconds - 2.5) < 0.01 && model.canvas.snapshot().map { !isRedFrame($0) } == true }
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.position == 0.5 && model.skimPosition == 2.5)
        #expect(model.player.currentItem === item && !model.playing)
        #expect(model.edit == original && model.selectedClipIDs == selection && !model.history.canUndo)
        #expect(try EditStorage.load(in: url, document: document) == saved)

        model.skim(nil)
        try await waitForSkimmer { abs(model.player.currentTime().seconds - 0.5) < 0.01 && model.canvas.snapshot().map(isRedFrame) == true }
        #expect(model.position == 0.5 && model.skimPosition == nil && model.error == nil)
    }

    @Test func playbackAfterRapidSkimmingStartsAtMainPlayhead() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        defer { model.close() }
        await model.open()
        try await waitForSkimmer { !model.loading && model.player.currentItem?.status == .readyToPlay }
        model.seek(0.5)
        model.skim(3.5)
        try await waitForSkimmer { abs(model.player.currentTime().seconds - 3.5) < 0.01 }
        // 最后一个鼠标请求仍在途中就按播放，旧定位完成后不能从鼠标位置起播。
        model.skim(3.0)
        model.togglePlayback()
        model.skim(3.8)
        try await waitForSkimmer { model.playing && model.player.rate == 1 }
        #expect(model.skimPosition == nil)
        #expect(model.player.currentTime().seconds >= 0.5 && model.player.currentTime().seconds < 1.5)
        model.pause()
        model.seek(1.25)
        model.skim(2.5)
        model.seek(0.75)
        try await waitForSkimmer { abs(model.player.currentTime().seconds - 0.75) < 0.01 && model.canvas.snapshot().map(isRedFrame) == true }
        #expect(model.position == 0.75 && model.skimPosition == nil)
        #expect(model.error == nil)
    }

    @Test func fallbackSkimmingDiscardsOldFramesAndReloadUsesLatestPreviewTime() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        defer { model.close() }
        await model.open()
        try await waitForSkimmer { !model.loading && model.player.currentItem?.status == .readyToPlay }
        // 模拟重建失败后仅离线静帧可用的分支，不访问录制设备。
        model.player.replaceCurrentItem(with: nil); model.canvas.attach(item: nil)
        model.seek(0.5)
        model.skim(2.5)
        await Task.yield()
        model.skim(nil)
        try await waitForSkimmer { model.canvas.image.map(isRedFrame) == true }
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.position == 0.5 && model.skimPosition == nil && model.canvas.image.map(isRedFrame) == true)
        model.skim(2.5)
        try await waitForSkimmer { model.canvas.image.map { !isRedFrame($0) } == true }
        model.reload()
        model.skim(3.0)
        try await waitForSkimmer { !model.loading && model.player.currentItem?.status == .readyToPlay && abs(model.player.currentTime().seconds - 3.0) < 0.01 }
        #expect(model.position == 0.5 && model.skimPosition == 3.0)
        model.skim(nil)
        try await waitForSkimmer { abs(model.player.currentTime().seconds - 0.5) < 0.01 && model.canvas.snapshot().map(isRedFrame) == true }
        #expect(model.error == nil)
    }

    @Test func repeatedSplittingSelectsActualTailAfterLayerReordering() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root, audio: true)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        defer { model.close() }
        await model.open()
        try await waitForSkimmer { !model.loading && model.player.currentItem?.status == .readyToPlay }
        let first = try #require(model.selectedClip)
        model.seek(1); model.split()
        let second = try #require(model.selectedClip)
        #expect(first != second && model.selectedClipIDs == [second])
        model.commit { $0.moveLayer(first, before: second) }
        model.seek(2); model.split()
        let third = try #require(model.selectedClip)
        #expect(third != second && third != first && model.selectedClipIDs == [third])
        #expect(model.edit.clips.first(where: { $0.id == third })?.timelineStart == 2)
        let order = model.edit.orderedLayerIDs
        let tailIndex = try #require(order.firstIndex(of: third))
        #expect(order.indices.contains(tailIndex + 1) && order[tailIndex + 1] == second)
        model.undo()
        #expect(!model.edit.clips.contains(where: { $0.id == third }))

        let audioID = try #require(model.edit.microphoneClips?.first?.id)
        model.selectedMedia = .microphone; model.selectedMediaID = audioID
        model.seek(2); model.split()
        let audioTail = try #require(model.selectedMediaID)
        #expect(audioTail != audioID && model.selectedMedia == .microphone)
        #expect(model.edit.microphoneClips?.first(where: { $0.id == audioTail })?.timelineStart == 2)
        #expect(model.error == nil)
    }

    private func waitForSkimmer(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SkimmerCheckError.timeout
    }
    private enum SkimmerCheckError: Error { case timeout }
}

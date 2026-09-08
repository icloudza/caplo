import Foundation
import Testing
import ProjectKit
import EditingCore
@testable import Features

/// 人像面板与工具栏"人像"项的可用性：录了摄像头才有；摄像头片段被删光后视为没有，撤销后恢复。
@MainActor
@Test func cameraPanelAvailabilityFollowsCameraClips() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("caplo-camera-availability-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "带摄像头")
    var document = ProjectDocument(name: "带摄像头")
    document.segments = [SegmentRecord(id: 0, duration: 2, files: [.screen: "Media/000000-screen.mov", .camera: "Media/000000-camera.mov"])]
    let model = VideoEditorModel(entry: LibraryEntry(url: url, document: document))
    defer { model.close() }
    model.ready = true  // 不真正打开媒体，只验证编辑状态；commit 要求就绪。
    #expect(model.hasCameraMedia)
    #expect(!model.cameraClipsDeleted)

    // 选中唯一的摄像头片段并删除：人像不可用，且能区分"删掉了"与"没录"。
    let clip = try #require(model.edit.mediaClips(.camera).first)
    model.selectedMedia = .camera; model.selectedMediaID = clip.id
    model.deleteSelection()
    #expect(model.edit.mediaClips(.camera).isEmpty)
    #expect(!model.hasCameraMedia)
    #expect(model.cameraClipsDeleted)

    // 撤销恢复片段后人像重新可用。
    model.undo()
    #expect(model.hasCameraMedia)

    // 根本没录摄像头的工程：不可用，也不算"删掉了"。
    var plain = ProjectDocument(name: "无摄像头")
    plain.segments = [SegmentRecord(id: 0, duration: 2, files: [.screen: "Media/000000-screen.mov"])]
    let plainModel = VideoEditorModel(entry: LibraryEntry(url: url, document: plain))
    defer { plainModel.close() }
    #expect(!plainModel.hasCameraMedia)
    #expect(!plainModel.cameraClipsDeleted)
}

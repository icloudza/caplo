import Foundation
import Testing
import ProjectKit
import EditingCore
@testable import Features

/// 添加镜头的统一入口：目标时间段已有镜头时先问，取消不加，确认加上；勾了"不再提示"之后直接加。
@MainActor
@Test func addingAFocusOverAnExistingOneAsksFirstAndCanBeSilenced() throws {
    let defaults = UserDefaults(suiteName: "caplo.tests.focus-prompt." + UUID().uuidString)!
    VideoEditorModel.defaults = defaults
    defer { VideoEditorModel.defaults = .standard }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("caplo-focus-prompt-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "录屏")
    var document = ProjectDocument(name: "录屏")
    document.segments = [SegmentRecord(id: 0, duration: 10, files: [.screen: "Media/000000-screen.mov"])]
    let model = VideoEditorModel(entry: LibraryEntry(url: url, document: document))
    defer { model.close() }
    model.ready = true
    model.addFocus(start: 1, duration: 2)
    #expect(model.edit.focuses.count == 1)
    // 不重叠：直接加，不问。
    model.requestAddFocus(start: 4, duration: 2)
    #expect(model.edit.focuses.count == 2 && model.pendingFocus == nil)
    // 重叠：先问；取消不加。
    model.requestAddFocus(start: 1.5, duration: 2)
    #expect(model.pendingFocus != nil && model.edit.focuses.count == 2)
    model.cancelPendingFocus()
    #expect(model.pendingFocus == nil && model.edit.focuses.count == 2)
    // 确认并勾"不再提示"：加上，之后同样的重叠不再问。
    model.requestAddFocus(start: 1.5, duration: 2)
    model.confirmPendingFocus(suppressFurtherPrompts: true)
    #expect(model.pendingFocus == nil && model.edit.focuses.count == 3)
    #expect(defaults.bool(forKey: VideoEditorModel.overlapPromptSuppressedKey))
    model.requestAddFocus(start: 1.6, duration: 1)
    #expect(model.pendingFocus == nil && model.edit.focuses.count == 4)
    // 播放头处添加同样走这个入口。
    model.seek(1.2)
    model.requestAddFocus()
    #expect(model.edit.focuses.count == 5)
}

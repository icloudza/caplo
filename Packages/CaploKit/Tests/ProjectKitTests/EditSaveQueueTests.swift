import Foundation
import Testing
import EditingCore
@testable import ProjectKit

/// 后台存盘：连续提交合并成一次、只写最后一份，`flush()` 同步等到落盘并带回结果；不调 `flush()` 时合并窗口过后
/// 也必须自己写下；写盘失败要能在等待时拿到错误，编辑器靠它决定窗口能不能关。
@Test func saveQueueWritesTheLatestEditAndReportsFailuresOnFlush() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "后台存盘")
    var document = ProjectDocument(name: "后台存盘")
    document.segments = [SegmentRecord(id: 0, duration: 4, files: [:])]
    var edit = VideoEdit(duration: 4)
    edit.materializeLayers()
    var versions: EditStorage.FileVersions?
    try EditStorage.save(edit, in: url, document: document, onDisk: &versions)
    #expect(versions == EditStorage.FileVersions(schema: edit.schemaVersion, focusEngine: edit.focusEngineVersion ?? 1))

    let queue = EditSaveQueue(url: url, document: document, onDisk: versions)
    for padding in stride(from: 10.0, through: 60, by: 10) {
        edit.layout.padding = padding
        queue.save(edit) { _ in }
    }
    let outcome = queue.flush()
    #expect(outcome.error == nil)
    #expect(outcome.number == 1, "连续提交写了 \(outcome.number) 次")
    #expect(try EditStorage.load(in: url, document: document).layout.padding == 60, "盘上不是最后一次提交的内容")

    // 不 flush：合并窗口（静候 0.25 秒）过后自己落盘。等不到就是延时写盘没接上，关窗前的改动全靠 flush 兜底。
    edit.layout.padding = 65
    queue.save(edit) { _ in }
    var landed = false
    for _ in 0..<60 where !landed {
        try await Task.sleep(for: .milliseconds(50))
        landed = (try? EditStorage.load(in: url, document: document).layout.padding) == 65
    }
    #expect(landed, "合并窗口过后没有自动写盘")

    // 编辑文件变成目录：写盘失败，flush 带回错误；恢复后再保存成功，编号继续增长。
    let path = url.appendingPathComponent("edits.json")
    try FileManager.default.removeItem(at: path)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    edit.layout.padding = 70
    queue.save(edit) { _ in }
    let failed = queue.flush()
    #expect(failed.error != nil && failed.number > outcome.number, "写盘失败没有报出来")
    try FileManager.default.removeItem(at: path)
    queue.save(edit) { _ in }
    let recovered = queue.flush()
    #expect(recovered.error == nil && recovered.number > failed.number)
    #expect(try EditStorage.load(in: url, document: document).layout.padding == 70)
}

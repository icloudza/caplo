import Foundation
import Testing
import EditingCore
@testable import ProjectKit

/// 恢复与读取的容错：同目录里的编辑备份、坏掉的片段日志、缺失的素材、读不出来的事件文件，
/// 都只影响它自己那一段，不能让整个工程恢复失败或打不开。
@Test func recoversJournalCommittedBeforeManifest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "恢复测试")
    let path = "Media/000000-screen.mov", second = "Media/000001-screen.mov"
    try Data([1]).write(to: url.appendingPathComponent(path))
    try Data([1]).write(to: url.appendingPathComponent(second))
    var record = SegmentRecord(id: 0, duration: 2, files: [.screen: path])
    record.eventsPath = "Events/000000.json.lzfse"
    try Data("坏掉的事件".utf8).write(to: url.appendingPathComponent(record.eventsPath!))
    try JSONEncoder().encode(record).write(to: url.appendingPathComponent("Recovery/000000.json"))
    var next = SegmentRecord(id: 1, duration: 3, files: [.screen: second])
    next.eventsPath = "Events/000001.json"
    try JSONEncoder().encode([PointerSample(time: 1, x: 0.5, y: 0.5, kind: .click)]).write(to: url.appendingPathComponent(next.eventsPath!))
    try JSONEncoder().encode(next).write(to: url.appendingPathComponent("Recovery/000001.json"))
    // 编辑数据的升级备份与录制日志同在 Recovery/，再放一条坏日志。
    try Data("{\"schemaVersion\":5}".utf8).write(to: url.appendingPathComponent("Recovery/edits-v5.json"))
    try Data("不是 JSON".utf8).write(to: url.appendingPathComponent("Recovery/000002.json"))
    let recovered = try ProjectStorage.recover(url)
    #expect(recovered.duration == 5)
    #expect(recovered.state == .recovered)

    // 坏的事件文件只跳过那一段：另一段的点击照常读到。
    let events = try EditStorage.events(in: url, document: recovered)
    #expect(events.count == 1 && events.first?.time == 3, "一段事件文件损坏拖垮了全部指针数据")

    // 素材丢了一个：工程照常读，缺的文件单独列出来。
    try FileManager.default.removeItem(at: url.appendingPathComponent(second))
    let loaded = try ProjectStorage.load(url)
    #expect(loaded.segments.count == 2, "缺一个素材整个工程就打不开")
    #expect(ProjectStorage.missingMedia(in: loaded, at: url) == [second])
}

@Test func refusesEscapingMediaPaths() throws {
    let root = URL(fileURLWithPath: "/tmp/project.caplo")
    #expect(throws: (any Error).self) { try ProjectStorage.mediaURL("Media/../../secret", in: root) }
    #expect(throws: (any Error).self) { try ProjectStorage.mediaURL("/etc/passwd", in: root) }
}

/// 重命名写入真实工程包，验证只改变显示名称且不会移动素材或损坏已有编辑数据。
@Test func renamePreservesProjectIdentityAndEdits() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "原名称")
    try ProjectStorage.complete(url)
    let original = try ProjectStorage.load(url)
    let edits = Data("{\"preserve\":true}".utf8)
    try edits.write(to: url.appendingPathComponent("edits.json"))
    try ProjectStorage.rename(url, to: "  新名称  ")
    let renamed = try ProjectStorage.load(url)
    #expect(renamed.name == "新名称")
    #expect(renamed.id == original.id)
    #expect(renamed.createdAt == original.createdAt)
    #expect(renamed.state == original.state)
    #expect(try Data(contentsOf: url.appendingPathComponent("edits.json")) == edits)
}


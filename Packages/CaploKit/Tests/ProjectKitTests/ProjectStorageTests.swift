import Foundation
import Testing
@testable import ProjectKit

@Test func recoversJournalCommittedBeforeManifest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "恢复测试")
    let path = "Media/000000-screen.mov"
    try Data([1]).write(to: url.appendingPathComponent(path))
    let record = SegmentRecord(id: 0, duration: 2, files: [.screen: path])
    try JSONEncoder().encode(record).write(to: url.appendingPathComponent("Recovery/000000.json"))
    let recovered = try ProjectStorage.recover(url)
    #expect(recovered.duration == 2)
    #expect(recovered.state == .recovered)
}

@Test func activeProjectCannotBeRecoveredConcurrently() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "租约测试")
    let lease = try ProjectLease(url: url)
    defer { withExtendedLifetime(lease) {} }
    #expect(throws: (any Error).self) { try ProjectStorage.recover(url) }
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

@Test func renameRejectsActiveLeaseAndBlankName() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "保留名称")
    #expect(throws: (any Error).self) { try ProjectStorage.rename(url, to: "录制中的新名称") }
    try ProjectStorage.complete(url)
    #expect(throws: (any Error).self) { try ProjectStorage.rename(url, to: " \n ") }
    let lease = try ProjectLease(url: url)
    defer { withExtendedLifetime(lease) {} }
    #expect(throws: (any Error).self) { try ProjectStorage.rename(url, to: "其他窗口修改") }
    #expect(try ProjectStorage.load(url).name == "保留名称")
}

import Foundation
import ImageIO
import CoreGraphics
import Testing
import EditingCore
@testable import ProjectKit

@Test func unsupportedEditFileRemainsUntouched() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "未知编辑格式")
    var edit = VideoEdit(duration: 5); edit.schemaVersion = 100
    let data = try JSONEncoder().encode(edit), path = url.appendingPathComponent("edits.json")
    try data.write(to: path)
    #expect(throws: EditError.self) { try EditStorage.load(in: url, document: ProjectDocument(name: "测试")) }
    #expect(try Data(contentsOf: path) == data)
}

/// 升版本号之前要留一份旧文件：升上去之后旧版 Caplo 打不开，用户退回去只能靠这份备份。
/// 叠加层已经不再升版本了，现在唯一的一次升级是"第一次进图层编辑"把 5 变成 6。
@Test func bumpingTheSchemaKeepsABackupOfThePreviousFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "版本备份")
    var document = ProjectDocument(name: "版本备份")
    document.segments = [SegmentRecord(id: 0, duration: 8, files: [:])]

    var edit = VideoEdit(duration: 8)
    try EditStorage.save(edit, in: url, document: document)
    #expect(edit.schemaVersion == 5)

    // 加遮罩不再改版本号，所以也不该产生备份。
    edit.addMask(MaskSegment(start: 0, duration: 2, x: 0.5, y: 0.5, width: 0.2, height: 0.1))
    try EditStorage.save(edit, in: url, document: document)
    let backup = url.appendingPathComponent("Recovery/edits-v5.json")
    #expect(edit.schemaVersion == 5)
    #expect(!FileManager.default.fileExists(atPath: backup.path), "版本没变却留了备份")

    // 第一次进图层编辑：5 → 6，这时才留一份。
    edit.prepareLayerEditing(camera: false, system: false, microphone: false)
    #expect(edit.schemaVersion == VideoEdit.writtenSchemaVersion)
    try EditStorage.save(edit, in: url, document: document)
    #expect(FileManager.default.fileExists(atPath: backup.path), "升到 6 之前没有留备份")
    let saved = try JSONSerialization.jsonObject(with: try Data(contentsOf: backup)) as? [String: Any]
    #expect(saved?["schemaVersion"] as? Int == 5)

    // 再存一次不会覆盖已有的备份。
    edit.addText(TextSegment(start: 0, duration: 2, text: "标题"))
    try EditStorage.save(edit, in: url, document: document)
    let again = try JSONSerialization.jsonObject(with: try Data(contentsOf: backup)) as? [String: Any]
    #expect(again?["schemaVersion"] as? Int == 5, "旧备份被后来的保存覆盖了")

    // 读回来内容一致。
    let loaded = try EditStorage.load(in: url, document: document)
    #expect(loaded.maskList.count == 1 && loaded.textList.count == 1)
}


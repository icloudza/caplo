import Foundation
import Testing
import EditingCore
@testable import ProjectKit

@Test func versionFourMigrationPreservesCameraAndDoesNotEnablePointerEffects() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "v4 光标迁移")
    var document = ProjectDocument(name: "旧画中画工程")
    document.segments = [SegmentRecord(id: 0, duration: 2, files: [:])]
    let data = Data(#"{"schemaVersion":4,"clips":[{"id":"00000000-0000-0000-0000-000000000001","sourceStart":0,"duration":2}],"layout":{"ratio":"16:9","background":"鸢尾","padding":40,"cornerRadius":12,"shadow":true},"audio":{"system":0.7,"microphone":1,"muted":[],"solo":[]},"focuses":[],"automaticFocus":true,"camera":{"enabled":true,"shape":"circle","size":0.24,"x":0.3,"y":0.8,"mirrored":false,"shadow":true}}"#.utf8)
    try data.write(to: url.appendingPathComponent("edits.json"))
    var edit = try EditStorage.load(in: url, document: document)
    #expect(edit.schemaVersion == 5 && edit.pointer == nil)
    #expect(edit.camera?.x == 0.3 && edit.camera?.mirrored == false)
    edit.pointer = PointerEffects(); edit.pointer?.cursorScale = 2; edit.pointer?.clicksVisible = false
    try EditStorage.save(edit, in: url, document: document)
    #expect(try Data(contentsOf: url.appendingPathComponent("Recovery/edits-v4.json")) == data)
    #expect(try EditStorage.load(in: url, document: document) == edit)
}

@Test func versionThreeMigrationKeepsOriginalAndCameraEditsReopen() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "v3 迁移")
    var document = ProjectDocument(name: "旧工程")
    document.segments = [SegmentRecord(id: 0, duration: 2, files: [:])]
    // 固定升级前格式，不让当前编码器替测试补齐新增字段。
    let data = Data(#"{"schemaVersion":3,"clips":[{"id":"00000000-0000-0000-0000-000000000001","sourceStart":0,"duration":2}],"layout":{"ratio":"16:9","background":"鸢尾","padding":40,"cornerRadius":12,"shadow":true},"audio":{"system":0.7,"microphone":1,"muted":[],"solo":[]},"focuses":[],"automaticFocus":true}"#.utf8)
    try data.write(to: url.appendingPathComponent("edits.json"))
    var edit = try EditStorage.load(in: url, document: document)
    #expect(edit.schemaVersion == 5 && edit.camera == nil)
    edit.camera = CameraLayout(); edit.camera?.mirrored = false; edit.camera?.x = 0.3
    try EditStorage.save(edit, in: url, document: document)
    #expect(try Data(contentsOf: url.appendingPathComponent("Recovery/edits-v3.json")) == data)
    #expect(try EditStorage.load(in: url, document: document) == edit)
}

@Test func migratesVersionTwoFocusesWithoutChangingPixelsOrLosingOriginalBytes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "v2 镜头迁移")
    var document = ProjectDocument(name: "测试")
    document.segments = [SegmentRecord(id: 0, duration: 8, files: [:])]
    var old = VideoEdit(duration: 8); old.schemaVersion = 2
    old.focuses = [FocusSegment(start: 2, duration: 2, x: 0.7, y: 0.4, automatic: true)]
    let original = try JSONEncoder().encode(old)
    try original.write(to: url.appendingPathComponent("edits.json"))
    let loaded = try EditStorage.load(in: url, document: document)
    #expect(loaded.schemaVersion == 5)
    #expect(loaded.focuses == old.focuses)
    #expect(SceneEvaluator.focus(edit: loaded, time: 2.3) == SceneEvaluator.focus(edit: old, time: 2.3))
    try EditStorage.save(loaded, in: url, document: document)
    #expect(try Data(contentsOf: url.appendingPathComponent("Recovery/edits-v2.json")) == original)
    #expect(try EditStorage.load(in: url, document: document) == loaded)
}

@Test func migratesAudioOnlyEditsWithRecoverableBackup() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "旧编辑格式")
    var document = ProjectDocument(name: "测试")
    document.segments = [SegmentRecord(id: 0, duration: 8, files: [:])]
    var levels = AudioLevels(); levels.system = 0.3
    // 固定真实 v1 字节，避免随当前编码器新增字段而把测试样本意外升级成新格式。
    let legacy = Data(#"{"system":0.3,"microphone":1}"#.utf8)
    try legacy.write(to: url.appendingPathComponent("edits.json"))
    var edit = try EditStorage.load(in: url, document: document)
    #expect(edit.audio == levels); _ = edit.split(at: 4)
    try EditStorage.save(edit, in: url, document: document)
    #expect(try Data(contentsOf: url.appendingPathComponent("Recovery/edits-v1.json")) == legacy)
    #expect(try EditStorage.load(in: url, document: document) == edit)
}

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

@Test func eventsRejectTraversalAndOffsetCommittedSegments() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "鼠标时间轴")
    var document = ProjectDocument(name: "测试")
    var segment = SegmentRecord(id: 1, duration: 3, files: [:]); segment.eventsPath = "Events/000001.json"
    document.segments = [SegmentRecord(id: 0, duration: 2, files: [:]), segment]
    try JSONEncoder().encode([PointerSample(time: 1, x: 0.4, y: 0.6, kind: .click)]).write(to: url.appendingPathComponent(segment.eventsPath!))
    #expect(try EditStorage.events(in: url, document: document).first?.time == 3)
    document.segments[1].eventsPath = "Events/../../outside.json"
    #expect(throws: ProjectError.self) { try EditStorage.events(in: url, document: document) }
}

@Test func upgradesAutomaticFollowAndBacksUpOriginalWithoutChangingManualFocus() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "连续跟随迁移")
    var document = ProjectDocument(name: "旧自动镜头")
    var segment = SegmentRecord(id: 0, duration: 8, files: [:])
    segment.eventsPath = "Events/000000.json"; document.segments = [segment]
    let samples = [PointerSample(time: 1, x: 0.2, y: 0.4, kind: .click), PointerSample(time: 2, x: 0.7, y: 0.5, kind: .click)]
    try JSONEncoder().encode(samples).write(to: url.appendingPathComponent(segment.eventsPath!))
    var old = VideoEdit(duration: 8); old.focusEngineVersion = 1
    let manual = FocusSegment(start: 6, duration: 1, x: 0.3, y: 0.6, automatic: false)
    old.focuses = [FocusSegment(start: 1, duration: 3, x: 0.2, y: 0.4, automatic: true), manual]
    let original = try JSONEncoder().encode(old)
    try original.write(to: url.appendingPathComponent("edits.json"))
    let loaded = try EditStorage.load(in: url, document: document)
    #expect(loaded.focusEngineVersion == 2)
    #expect(loaded.focuses.filter { !$0.automatic } == [manual])
    #expect(loaded.focuses.contains { $0.automatic && $0.sampledPath == true })
    #expect(try Data(contentsOf: url.appendingPathComponent("edits.json")) == original)
    try EditStorage.save(loaded, in: url, document: document)
    #expect(try Data(contentsOf: url.appendingPathComponent("Recovery/edits-focus-v1.json")) == original)
    #expect(try EditStorage.load(in: url, document: document) == loaded)
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

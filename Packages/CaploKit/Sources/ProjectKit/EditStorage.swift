import Foundation
import EditingCore

/// 调用方在编辑会话全程持有工程租约；旧版仅音量的 edits.json 在首次成功保存前保留备份。
public enum EditStorage {
    public static func load(in url: URL, document: ProjectDocument) throws -> VideoEdit {
        let path = url.appendingPathComponent("edits.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            var edit = VideoEdit(duration: document.duration)
            if document.segments.contains(where: { $0.files[.camera] != nil }) { edit.camera = CameraLayout() }
            if document.capture?.pointerEnabled == true {
                edit.pointer = .recommended
                let samples = try events(in: url, document: document)
                if samples.contains(where: { $0.cursorAssetID != nil }) { edit.pointer?.style = .captured }
            }
            edit.focusEngineVersion = 2
            edit.focuses = AutoFocus.generate(events: try events(in: url, document: document), duration: document.duration)
            return edit
        }
        let data = try Data(contentsOf: path)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        var edit: VideoEdit
        if object?["schemaVersion"] != nil { edit = try JSONDecoder().decode(VideoEdit.self, from: data) }
        else {
            guard Set(object?.keys.map { $0 } ?? []) == Set(["system", "microphone"]) else { throw EditError.invalid }
            var migrated = VideoEdit(duration: document.duration)
            migrated.audio = try JSONDecoder().decode(AudioLevels.self, from: data)
            edit = migrated
        }
        if (2...4).contains(edit.schemaVersion) { edit.schemaVersion = 5 }
        if (edit.focusEngineVersion ?? 1) < 2, edit.focuses.contains(where: { $0.automatic }) {
            let samples = try events(in: url, document: document)
            if !samples.isEmpty {
                edit.focuses.removeAll { $0.automatic }
                edit.focuses += AutoFocus.generate(events: samples, duration: document.duration, style: edit.focusStyle ?? AutoFocusStyle())
                edit.focusEngineVersion = 2
            }
        }
        // 旧工程可能留下超出录制画面的效果尾巴，先收紧范围再验证，原文件仍保留到成功保存。
        edit.constrainTimelineFocuses()
        edit.normalizeTimelineRows()
        try edit.validate(sourceDuration: document.duration)
        return edit
    }

    public static func save(_ edit: VideoEdit, in url: URL, document: ProjectDocument) throws {
        try edit.validate(sourceDuration: document.duration)
        let path = url.appendingPathComponent("edits.json")
        if let data = try? Data(contentsOf: path),
           let old = try JSONSerialization.jsonObject(with: data) as? [String: Any], old["schemaVersion"] == nil || [2, 3, 4].contains(old["schemaVersion"] as? Int ?? 0) || (edit.schemaVersion == 6 && old["schemaVersion"] as? Int == 5) {
            let version = old["schemaVersion"] as? Int ?? 1
            let backup = url.appendingPathComponent("Recovery/edits-v\(version).json")
            if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic) }
        }
        if let data = try? Data(contentsOf: path),
           let old = try JSONSerialization.jsonObject(with: data) as? [String: Any], (old["focusEngineVersion"] as? Int ?? 1) < 2, edit.focusEngineVersion == 2 {
            let backup = url.appendingPathComponent("Recovery/edits-focus-v1.json")
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic) }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(edit).write(to: path, options: .atomic)
    }

    public static func events(in url: URL, document: ProjectDocument) throws -> [PointerSample] {
        var result: [PointerSample] = [], cursor = 0.0
        for segment in document.segments.sorted(by: { $0.id < $1.id }) {
            defer { cursor += segment.duration }
            guard let path = segment.eventsPath else { continue }
            // 事件索引也必须限制在工程内部，不能借助相对路径或符号链接读取外部文件。
            let root = url.resolvingSymlinksInPath().standardizedFileURL.path + "/Events/"
            let file = url.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard path.hasPrefix("Events/"), !path.contains(".."), file.path.hasPrefix(root) else { throw ProjectError.invalid("事件路径无效。") }
            let samples = try JSONDecoder().decode([PointerSample].self, from: Data(contentsOf: file))
            for var sample in samples where sample.time.isFinite && sample.time >= 0 && sample.time < segment.duration && (0...1).contains(sample.x) && (0...1).contains(sample.y) {
                sample.time += cursor; result.append(sample)
            }
        }
        return result.sorted { $0.time < $1.time }
    }
}

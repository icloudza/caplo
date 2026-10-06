import Foundation
import EditingCore

/// 调用方在编辑会话全程持有工程租约；旧版仅音量的 edits.json 在首次成功保存前保留备份。
public enum EditStorage {
    /// `wallpaper`：当前桌面壁纸文件，只在**新建**这份编辑数据时用作默认背景。
    /// 取壁纸要碰 `NSScreen`，得在主线程上问，所以由调用方取好传进来（`DesktopWallpaper.currentURL()`）。
    public static func load(in url: URL, document: ProjectDocument, wallpaper: URL? = nil) throws -> VideoEdit {
        let path = url.appendingPathComponent("edits.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            var edit = VideoEdit(duration: document.duration)
            // 默认背景就是这台机器此刻的桌面壁纸：录屏摆在自己的桌面上最自然。
            // 读不到、写不进都不算错——退回渐变即可，不能让新工程因此打不开。
            if let wallpaper, let imported = try? DesktopWallpaper.importWallpaper(wallpaper, into: url) {
                edit.layout.backgroundImage = imported
            }
            if document.segments.contains(where: { $0.files[.camera] != nil }) { edit.camera = CameraLayout() }
            // 指针事件只解析一次：光标样式判断与自动镜头共用（长录制的事件文件解析两遍要多花几百毫秒）。
            let samples = try events(in: url, document: document)
            if document.capture?.pointerEnabled == true {
                edit.pointer = .recommended
                if samples.contains(where: { $0.cursorAssetID != nil }) { edit.pointer?.style = .captured }
            }
            edit.focusEngineVersion = 2
            edit.focuses = AutoFocus.generate(events: samples, duration: document.duration)
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
        edit.resolveLegacyAutoTextColors()
        edit.constrainTimelineFocuses()
        edit.normalizeTimelineRows()
        try edit.validate(sourceDuration: document.duration)
        return edit
    }

    /// 盘上那份编辑数据的版本号：决定这次保存要不要先留备份。
    public struct FileVersions: Equatable, Sendable {
        public var schema: Int
        public var focusEngine: Int
        public init(schema: Int, focusEngine: Int) { self.schema = schema; self.focusEngine = focusEngine }
    }

    public static func save(_ edit: VideoEdit, in url: URL, document: ProjectDocument) throws {
        var unknown: FileVersions?
        try save(edit, in: url, document: document, onDisk: &unknown)
    }

    /// `onDisk`：调用方记得的盘上版本。知道就不再读旧文件——以前每次保存都把旧文件整份读两遍、解析两遍，
    /// 带长运镜路径的工程每改一下都要多花几十到几百毫秒。不知道（nil）时读一次，写完更新成这次写下的版本。
    public static func save(_ edit: VideoEdit, in url: URL, document: ProjectDocument, onDisk: inout FileVersions?) throws {
        try edit.validate(sourceDuration: document.duration)
        let path = url.appendingPathComponent("edits.json")
        let target = FileVersions(schema: edit.schemaVersion, focusEngine: edit.focusEngineVersion ?? 1)
        let old = onDisk ?? versions(at: path)
        // 每次升版本号之前留一份旧文件：升上去之后旧版 Caplo 就打不开了，
        // 用户要退回去只能靠这份备份。每个版本只留第一份，不会越攒越多。
        if let old, old.schema < target.schema || (old.focusEngine < 2 && target.focusEngine == 2), let data = try? Data(contentsOf: path) {
            if old.schema < target.schema { try backup(data, as: "Recovery/edits-v\(old.schema).json", in: url) }
            if old.focusEngine < 2, target.focusEngine == 2 { try backup(data, as: "Recovery/edits-focus-v1.json", in: url) }
        }
        // 不再缩进排版：文件只给程序读，缩进会让体积翻倍、编码变慢；键排序保留，内容不变时字节不变。
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(edit).write(to: path, options: .atomic)
        onDisk = target
    }

    /// 只解析版本号两个字段；文件不存在或读不出来返回 nil（没有旧文件就不需要备份）。
    static func versions(at path: URL) -> FileVersions? {
        struct Header: Decodable { var schemaVersion: Int?; var focusEngineVersion: Int? }
        guard let data = try? Data(contentsOf: path), let header = try? JSONDecoder().decode(Header.self, from: data) else { return nil }
        return FileVersions(schema: header.schemaVersion ?? 1, focusEngine: header.focusEngineVersion ?? 1)
    }

    private static func backup(_ data: Data, as relative: String, in url: URL) throws {
        let backup = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic) }
    }

    /// 只把遮罩读出来，不做迁移也不做校验。缩略图这类"不载入整个工程也要打码"的路径用它。
    /// 读不出来就抛错，让调用方选择不显示画面——这里绝不能 fail-open 成"没有遮罩"。
    public static func maskList(in url: URL) throws -> [MaskSegment] {
        let path = url.appendingPathComponent("edits.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let data = try Data(contentsOf: path)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw EditError.invalid }
        guard object["masks"] != nil else { return [] }
        struct MasksOnly: Decodable { var masks: [MaskSegment]? }
        return try JSONDecoder().decode(MasksOnly.self, from: data).masks ?? []
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

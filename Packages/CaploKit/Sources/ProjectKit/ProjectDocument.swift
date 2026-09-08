import Foundation
import Darwin

public enum MediaRole: String, Codable, Sendable, CaseIterable {
    case screen, systemAudio, microphone, camera

    /// 摄像头与屏幕都是独立视频，新增素材类型时不能把所有非屏幕轨道当作声音。
    public var isVideo: Bool { self == .screen || self == .camera }
}

public struct SegmentRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var duration: Double
    public var eventsPath: String?
    public var files: [MediaRole: String]
    /// 素材零时刻相对片段起点的偏移；缺省为零，兼容此前工程。
    /// 摄像头可能晚于屏幕提供首帧，偏移不能仅从容器 timeRange 推断。
    public var mediaOffsets: [MediaRole: Double]?
    public init(id: Int, duration: Double, files: [MediaRole: String]) {
        self.id = id; self.duration = duration; self.files = files
    }
    public func offset(for role: MediaRole) -> Double { mediaOffsets?[role] ?? 0 }
}

/// 记录开始时的采集几何；鼠标事件同时记录变化后的桌面区域，便于复核多显示器及窗口移动。
public struct CaptureMetadata: Codable, Sendable {
    public var desktopBounds: CGRect
    public var pixelSize: CGSize
    public var pointPixelScale: Double
    public var microphoneDeviceID: String?
    public var cameraDeviceID: String?
    public var systemAudioApplicationBundleIDs: [String]?
    public var systemAudioEnabled: Bool?
    public var pointerEnabled: Bool
    public var cursorEmbedded: Bool?
    /// 录制帧率；旧工程缺省按 30。
    public var frameRate: Double?
    public init(desktopBounds: CGRect, pixelSize: CGSize, pointPixelScale: Double, pointerEnabled: Bool) {
        self.desktopBounds = desktopBounds; self.pixelSize = pixelSize
        self.pointPixelScale = pointPixelScale; self.pointerEnabled = pointerEnabled
    }
}

public struct ProjectDocument: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case recording, completed, recovered }
    public var schemaVersion = 1
    public var id = UUID()
    public var name: String
    public var createdAt = Date()
    public var state: State = .recording
    public var segments: [SegmentRecord] = []
    public var warning: String?
    public var capture: CaptureMetadata?
    public var duration: Double { segments.reduce(0) { $0 + $1.duration } }
    /// 播放与导出的输出帧率，与录制帧率一致；旧工程为 30。
    public var frameRate: Double {
        guard let rate = capture?.frameRate, rate.isFinite, rate >= 24, rate <= 120 else { return 30 }
        return rate
    }
    public init(name: String) { self.name = name }
}

public enum ProjectError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): message } }
}

/// 工程目录持有排他租约，防止恢复扫描或另一个进程同时修改正在录制的工程。
/// flock 随进程退出释放，崩溃后无需猜测上次录制是否仍然活跃。
public final class ProjectLease: @unchecked Sendable {
    private let descriptor: Int32
    public init(url: URL) throws {
        let fd = Darwin.open(url.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ProjectError.invalid("无法锁定工程。") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ProjectError.invalid("工程正在录制或被其他窗口修改，请稍后再试。")
        }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

/// 素材先完成写入，片段日志再原子提交，最后更新索引；恢复时以日志补齐索引。
/// 写入方必须持有 ProjectLease，读取方只能看见已提交的片段。
public enum ProjectStorage {
    public static var libraryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Caplo/Projects", isDirectory: true)
    }

    public static func create(in root: URL = libraryURL, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("\(UUID().uuidString).caplo", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        for directory in ["Media", "Recovery", "Cache", "Events"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(directory), withIntermediateDirectories: false)
        }
        try save(ProjectDocument(name: name), to: url)
        return url
    }

    public static func load(_ url: URL) throws -> ProjectDocument {
        let data = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        let document = try JSONDecoder().decode(ProjectDocument.self, from: data)
        guard document.schemaVersion == 1 else { throw ProjectError.invalid("此工程版本暂不支持，请使用创建它的 Caplo 版本打开。") }
        try validate(document.segments, in: url)
        return document
    }

    public static func save(_ document: ProjectDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url.appendingPathComponent("manifest.json"), options: .atomic)
    }

    /// 仅改工程显示名称，不移动文件包；独占租约防止覆盖录制或编辑中的元数据。
    public static func rename(_ url: URL, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectError.invalid("项目名称不能为空。") }
        let lease = try ProjectLease(url: url)
        defer { withExtendedLifetime(lease) {} }
        var document = try load(url)
        guard document.state != .recording else { throw ProjectError.invalid("请先完成录制或恢复工程，再修改名称。") }
        document.name = trimmed
        try save(document, to: url)
    }

    public static func commit(_ segment: SegmentRecord, to url: URL) throws {
        try validate([segment], in: url)
        let log = url.appendingPathComponent(String(format: "Recovery/%06d.json", segment.id))
        try JSONEncoder().encode(segment).write(to: log, options: .atomic)
        var document = try load(url)
        guard !document.segments.contains(where: { $0.id == segment.id }) else { return }
        document.segments.append(segment)
        document.segments.sort { $0.id < $1.id }
        try save(document, to: url)
    }

    public static func complete(_ url: URL, warning: String? = nil) throws {
        var document = try load(url)
        document.state = .completed
        document.warning = warning
        try save(document, to: url)
    }

    public static func recover(_ url: URL) throws -> ProjectDocument {
        let lease = try ProjectLease(url: url)
        defer { withExtendedLifetime(lease) {} }
        var document = try load(url)
        guard document.state == .recording else { return document }
        let logs = try FileManager.default.contentsOfDirectory(at: url.appendingPathComponent("Recovery"), includingPropertiesForKeys: nil)
        var recovered = Dictionary(uniqueKeysWithValues: document.segments.map { ($0.id, $0) })
        for log in logs where log.pathExtension == "json" {
            let segment = try JSONDecoder().decode(SegmentRecord.self, from: Data(contentsOf: log))
            try validate([segment], in: url)
            recovered[segment.id] = segment
        }
        document.segments = recovered.values.sorted { $0.id < $1.id }
        document.state = .recovered
        document.warning = "上次录制意外中断，已恢复所有提交片段。正在写入及尚未完成提交的尾段可能缺失。"
        try save(document, to: url)
        return document
    }

    public static func mediaURL(_ path: String, in project: URL) throws -> URL {
        // 工程可能来自外部文件，拒绝路径穿越和符号链接指向工程之外。
        let root = project.resolvingSymlinksInPath().standardizedFileURL
        let result = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard path.hasPrefix("Media/"), !path.contains(".."),
              result.path.hasPrefix(root.path + "/Media/") else {
            throw ProjectError.invalid("工程包含无效素材路径。")
        }
        return result
    }

    /// 自定义背景图限制在工程包 `Backgrounds/` 内，拒绝路径穿越。
    public static func backgroundURL(_ path: String, in project: URL) throws -> URL {
        let root = project.resolvingSymlinksInPath().standardizedFileURL
        let result = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard path.hasPrefix("Backgrounds/"), !path.contains(".."), result.path.hasPrefix(root.path + "/Backgrounds/") else {
            throw ProjectError.invalid("工程包含无效背景图路径。")
        }
        return result
    }

    /// 把用户选择的图片复制进工程包，返回相对路径；不修改 manifest。
    public static func importBackground(from source: URL, into project: URL) throws -> String {
        let extensionName = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let path = "Backgrounds/\(UUID().uuidString).\(extensionName)"
        let destination = try backgroundURL(path, in: project)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        return path
    }

    private static func validate(_ segments: [SegmentRecord], in url: URL) throws {
        var ids = Set<Int>()
        for segment in segments {
            guard segment.id >= 0, ids.insert(segment.id).inserted,
                  segment.duration.isFinite, segment.duration > 0,
                  segment.files[.screen] != nil else { throw ProjectError.invalid("工程片段索引损坏。") }
            for (role, offset) in segment.mediaOffsets ?? [:] {
                guard segment.files[role] != nil, offset.isFinite, offset >= 0, offset < segment.duration,
                      role != .screen || offset == 0 else { throw ProjectError.invalid("工程素材时间偏移损坏。") }
            }
            for path in segment.files.values {
                let file = try mediaURL(path, in: url)
                guard FileManager.default.fileExists(atPath: file.path) else { throw ProjectError.invalid("工程素材丢失：\(path)") }
            }
        }
    }
}

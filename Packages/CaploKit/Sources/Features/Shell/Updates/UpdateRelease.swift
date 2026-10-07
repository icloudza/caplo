import Foundation
import Sparkle

/// 一个可安装的新版本（取自 appcast 条目）。界面只认这个类型，不直接接触 Sparkle 对象，离屏预览可以直接构造。
struct UpdateRelease: Equatable, Sendable {
    /// 展示版本（CFBundleShortVersionString），例如 1.3.0。
    var version: String
    /// 比较用的构建号（CFBundleVersion）。
    var build: String
    var date: Date?
    /// 更新说明：发布流水线写入的纯文本，支持 `#` 标题、`-` 列表与行内 Markdown。
    var notes: String
    /// 安装包字节数；appcast 没写时为 nil。
    var size: UInt64?
    /// 重要更新：不提供"跳过此版本"。
    var critical = false
    /// 只有说明、没有安装包（需要到官网手动下载的版本）：主按钮改为打开 `infoURL`。
    var informationOnly = false
    var infoURL: URL?
}

extension UpdateRelease {
    init(item: SUAppcastItem) {
        self.init(version: item.displayVersionString, build: item.versionString, date: item.date,
                  notes: Self.plainNotes(item.itemDescription ?? "", format: item.itemDescriptionFormat),
                  size: item.contentLength > 0 ? item.contentLength : nil,
                  critical: item.isCriticalUpdate, informationOnly: item.isInformationOnlyUpdate, infoURL: item.infoURL)
    }

    /// appcast 里的说明默认按 HTML 解释；流水线写的是 plain-text。HTML 的说明（或单独下载的说明页）转成纯文本再排版。
    static func plainNotes(_ text: String, format: String?) -> String {
        guard format == nil || format == "html", text.contains("<") else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return html(Data(text.utf8))
    }

    static func html(_ data: Data) -> String {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.html,
                                                                          .characterEncoding: String.Encoding.utf8.rawValue]
        let string = (try? NSAttributedString(data: data, options: options, documentAttributes: nil))?.string ?? String(decoding: data, as: UTF8.self)
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 更新说明的排版块。只认三种：标题、列表项、段落；其余 Markdown 交给行内解析（粗体、代码、链接）。
enum ReleaseNoteBlock: Equatable {
    case heading(String)
    case bullet(String)
    case paragraph(String)

    static func parse(_ text: String) -> [ReleaseNoteBlock] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? nil : .heading(title)
            }
            for marker in ["- ", "* ", "• ", "· "] where line.hasPrefix(marker) {
                return .bullet(String(line.dropFirst(marker.count)))
            }
            // 有序列表"1. xxx"也按列表项排，序号本身不保留（发布说明里顺序没有含义）。
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].first == " " {
                return .bullet(String(line[line.index(dot, offsetBy: 2)...]))
            }
            return .paragraph(line)
        }
    }
}

/// 更新流程里的错误，翻成给用户看的短句；取消类返回 nil（用户自己取消的不提示）。
enum UpdateErrorText {
    static func message(for error: Error) -> String? {
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            return error.code == NSURLErrorCancelled ? nil : "无法连接更新服务器，请检查网络。"
        }
        guard error.domain == SUSparkleErrorDomain, let code = SUError(rawValue: OSStatus(error.code)) else { return error.localizedDescription }
        switch code {
        case .installationCanceledError, .noUpdateError: return nil
        case .downloadError: return "下载失败，请检查网络后重试。"
        case .appcastError, .appcastParseError, .resumeAppcastError: return "读取更新信息失败，请稍后再试。"
        case .signatureError, .validationError, .notValidUpdateError: return "更新包校验未通过，已停止安装。"
        case .runningFromDiskImageError: return "请先把 Caplo 拖到\u{201C}应用程序\u{201D}文件夹。"
        case .installationWriteNoPermissionError: return "没有权限替换当前的 Caplo，请从官网下载新版本。"
        case .unarchivingError: return "更新包解压失败，请重试。"
        case .installationAuthorizeLaterError: return nil
        default: return error.localizedDescription
        }
    }
}

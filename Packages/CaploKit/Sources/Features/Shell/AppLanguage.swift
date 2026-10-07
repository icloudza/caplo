import AppKit

/// 界面语言：默认跟随系统（系统中文即中文，其余语言用英文）；设置里可手动指定，重新打开 Caplo 后生效。
///
/// 手动指定写的是本应用域里的 `AppleLanguages`，这是 macOS 应用单独换语言的标准做法；"跟随系统"就是删掉这个覆盖。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, chinese = "zh-Hans", english = "en"
    var id: Self { self }

    /// 各语言用自己的写法显示（与 macOS 语言列表一致），只有"跟随系统"随界面翻译。
    var title: String {
        switch self {
        case .system: String(localized: "跟随系统")
        case .chinese: "简体中文"
        case .english: "English"
        }
    }

    private static let key = "AppleLanguages"

    /// 当前设置：只看本应用域，不看全局域（全局域就是系统语言列表）。
    static var selection: AppLanguage {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: bundleID)?[key] as? [String],
              let first = languages.first else { return .system }
        return first.hasPrefix("zh") ? .chinese : first.hasPrefix("en") ? .english : .system
    }

    static func select(_ language: AppLanguage) {
        if language == .system { UserDefaults.standard.removeObject(forKey: key) }
        else { UserDefaults.standard.set([language.rawValue], forKey: key) }
    }

    /// 系统首选语言是不是中文：读全局偏好，不受本应用 `AppleLanguages` 覆盖的影响。
    static var systemPrefersChinese: Bool {
        let global = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        return (global?.first ?? "en").hasPrefix("zh")
    }

    /// 这次启动实际显示的语言（启动时就定了，改设置要重新打开才变）。
    static var running: AppLanguage {
        (Bundle.main.preferredLocalizations.first ?? "zh-Hans").hasPrefix("zh") ? .chinese : .english
    }
}

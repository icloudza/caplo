import Foundation

/// 界面语言对应的区域设置：日期、数字、相对时间按界面语言排版，地区（日历、度量）仍跟系统。
///
/// 界面语言由主包已有的本地化与用户偏好决定（`Bundle.main.preferredLocalizations`），可能与系统语言不同
/// （设置里选了 English，或系统是日语等未翻译的语言时退回英文）。直接用 `Locale.current` 会出现英文界面里夹着中文日期。
public enum AppLocale {
    public static var current: Locale {
        let language = Bundle.main.preferredLocalizations.first ?? "zh-Hans"
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(identifier: language)
        return Locale(components: components)
    }
}

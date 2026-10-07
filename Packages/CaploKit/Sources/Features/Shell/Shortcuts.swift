import SwiftUI
import AppKit
import CaploDesignSystem

/// 一个快捷键：基准字符（不受 ⇧ 影响的那个，小写）+ 修饰键。存盘用，也直接换成 SwiftUI 的 `KeyEquivalent` 与按键事件比对。
struct KeyCombo: Codable, Hashable, Sendable {
    /// 单个字符；空格就是 " "。只收可打印字符，方向键、回车、删除、Esc 等留给固定用途。
    var key: String
    var command = false, shift = false, option = false, control = false

    init(_ key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key.lowercased(); self.command = command; self.shift = shift; self.option = option; self.control = control
    }

    /// 从按键事件取：字符按"不加任何修饰"重新排一次键位，⇧⌘, 得到 ","（而不是 "<"），和菜单匹配的口径一致。
    /// 不可打印的键（方向键、F 键、回车、删除、Esc 等）返回 nil。
    init?(event: NSEvent) {
        guard let raw = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers, raw.count == 1,
              let scalar = raw.unicodeScalars.first,
              scalar == " " || (!CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value) && !CharacterSet.whitespacesAndNewlines.contains(scalar))
        else { return nil }
        let flags = event.modifierFlags
        self.init(raw, command: flags.contains(.command), shift: flags.contains(.shift), option: flags.contains(.option), control: flags.contains(.control))
    }

    var hasPrimaryModifier: Bool { command || control }
    var keyEquivalent: KeyEquivalent { KeyEquivalent(Character(key)) }
    var modifiers: EventModifiers {
        var result: EventModifiers = []
        if command { result.insert(.command) }; if shift { result.insert(.shift) }
        if option { result.insert(.option) }; if control { result.insert(.control) }
        return result
    }

    /// 按 macOS 菜单的习惯顺序：⌃⌥⇧⌘ + 键名。
    var display: String {
        let name = key == " " ? String(localized: "空格") : key.uppercased()
        return (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + name
    }

    /// SwiftUI `onKeyPress` 的按键：字符同样按小写比，修饰键只看这四个。
    func matches(_ press: KeyPress) -> Bool {
        press.key.character.lowercased() == key
            && press.modifiers.contains(.command) == command && press.modifiers.contains(.shift) == shift
            && press.modifiers.contains(.option) == option && press.modifiers.contains(.control) == control
    }
}

/// 可以改键的动作。方向键逐帧、⌫ 删除、Esc、回车、⌘1–⌘9 切面板与滚轮手势属于系统 / 编辑器约定，固定不改。
enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case newRecording, openProject, projectLibrary, settings
    case recordDisplay, recordRegion, recordWindow
    case librarySearch, librarySelectAll
    case playPause, split, undo, redo, duplicate, selectAllClips, export

    var id: Self { self }

    /// 作用范围：同一范围内不能重复；`global` 是主菜单命令，任何窗口在前都生效，所以和所有范围都算冲突。
    enum Scope: String, CaseIterable {
        case global = "全局", recorder = "录制方式条", library = "项目中心", editor = "编辑器"
        var title: String {
            switch self {
            case .global: String(localized: "全局"); case .recorder: String(localized: "录制方式条")
            case .library: String(localized: "项目中心"); case .editor: String(localized: "编辑器")
            }
        }
    }

    var scope: Scope {
        switch self {
        case .newRecording, .openProject, .projectLibrary, .settings: .global
        case .recordDisplay, .recordRegion, .recordWindow: .recorder
        case .librarySearch, .librarySelectAll: .library
        case .playPause, .split, .undo, .redo, .duplicate, .selectAllClips, .export: .editor
        }
    }

    var title: String {
        switch self {
        case .newRecording: String(localized: "新建录制"); case .openProject: String(localized: "打开工程"); case .projectLibrary: String(localized: "项目中心"); case .settings: String(localized: "设置")
        case .recordDisplay: String(localized: "全屏"); case .recordRegion: String(localized: "自定义区域"); case .recordWindow: String(localized: "窗口")
        case .librarySearch: String(localized: "搜索"); case .librarySelectAll: String(localized: "全选")
        case .playPause: String(localized: "播放 / 暂停"); case .split: String(localized: "分割"); case .undo: String(localized: "撤销"); case .redo: String(localized: "重做")
        case .duplicate: String(localized: "复制片段"); case .selectAllClips: String(localized: "全选片段"); case .export: String(localized: "导出")
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .newRecording: KeyCombo("n", command: true)
        case .openProject: KeyCombo("o", command: true)
        case .projectLibrary: KeyCombo("p", command: true, shift: true)
        case .settings: KeyCombo(",", command: true)
        case .recordDisplay: KeyCombo("1")
        case .recordRegion: KeyCombo("2")
        case .recordWindow: KeyCombo("3")
        case .librarySearch: KeyCombo("f", command: true)
        case .librarySelectAll: KeyCombo("a", command: true)
        case .playPause: KeyCombo(" ")
        case .split: KeyCombo("b", command: true)
        case .undo: KeyCombo("z", command: true)
        case .redo: KeyCombo("z", command: true, shift: true)
        case .duplicate: KeyCombo("d", command: true)
        case .selectAllClips: KeyCombo("a", command: true)
        case .export: KeyCombo("e", command: true)
        }
    }
}

/// 快捷键表：默认值 + 用户改过的覆盖（只存改过的，默认值以后调整时没改过的人跟着变）。
/// 菜单、按钮的 `keyboardShortcut`、时间线与项目中心的按键处理都从这里取，改完立即生效，不用重启。
@MainActor @Observable
final class ShortcutStore {
    static let shared = ShortcutStore()
    static let defaultsKey = "shortcuts.v1"

    private(set) var overrides: [ShortcutAction: KeyCombo]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = (defaults.data(forKey: Self.defaultsKey)).flatMap { try? JSONDecoder().decode([String: KeyCombo].self, from: $0) } ?? [:]
        overrides = Dictionary(uniqueKeysWithValues: stored.compactMap { key, combo in ShortcutAction(rawValue: key).map { ($0, combo) } })
    }

    func combo(_ action: ShortcutAction) -> KeyCombo { overrides[action] ?? action.defaultCombo }
    func display(_ action: ShortcutAction) -> String { combo(action).display }
    var isCustomized: Bool { !overrides.isEmpty }

    /// 在 `scope` 里这次按键对应的动作（全局命令也算进来）；时间线这类自己处理 keyDown 的视图用它分派。
    func action(for event: NSEvent, in scope: ShortcutAction.Scope) -> ShortcutAction? {
        guard let pressed = KeyCombo(event: event) else { return nil }
        return ShortcutAction.allCases.first { $0.scope == scope && combo($0) == pressed }
    }

    /// 改键前的检查，返回给用户看的原因；nil 表示可以用。
    func problem(assigning candidate: KeyCombo, to action: ShortcutAction) -> String? {
        if let reason = Self.reservedReason(candidate, scope: action.scope) { return reason }
        // 主菜单命令不带 ⌘ / ⌃ 会在打字时被菜单截走。
        if action.scope == .global, !candidate.hasPrimaryModifier { return String(localized: "全局快捷键需要包含 ⌘ 或 ⌃") }
        if let other = ShortcutAction.allCases.first(where: {
            $0 != action && combo($0) == candidate && ($0.scope == action.scope || $0.scope == .global || action.scope == .global)
        }) {
            return String(localized: "\(candidate.display) 已用于「\(other.scope.title) · \(other.title)」")
        }
        return nil
    }

    /// 写入一个快捷键；与默认值相同就去掉覆盖。调用前先过 `problem`。
    func assign(_ candidate: KeyCombo, to action: ShortcutAction) {
        overrides[action] = candidate == action.defaultCombo ? nil : candidate
        persist()
    }

    func reset(_ action: ShortcutAction) { overrides[action] = nil; persist() }
    func resetAll() { overrides.removeAll(); persist() }

    private func persist() {
        let stored = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        if stored.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) }
        else if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// 系统与应用固定占用的组合：退出 / 关窗 / 隐藏 / 最小化 / 剪贴板，编辑器的 ⌘1–⌘9 切面板，导航条的 + − =。
    static func reservedReason(_ combo: KeyCombo, scope: ShortcutAction.Scope) -> String? {
        let commandOnly = combo.command && !combo.shift && !combo.option && !combo.control
        if commandOnly, ["q", "w", "h", "m", "c", "v", "x", "`"].contains(combo.key) { return String(localized: "\(combo.display) 是系统快捷键，不能占用") }
        if combo.command, combo.option, !combo.shift, !combo.control, ["h", "w", "m"].contains(combo.key) { return String(localized: "\(combo.display) 是系统快捷键，不能占用") }
        if commandOnly, scope == .editor || scope == .global, Int(combo.key).map({ (1...9).contains($0) }) == true {
            return String(localized: "⌘1 – ⌘9 固定用于编辑器切换面板")
        }
        if !combo.command, !combo.control, !combo.option, scope == .editor || scope == .global, ["+", "=", "-"].contains(combo.key) {
            return String(localized: "\(combo.display) 固定用于缩放时间线导航条")
        }
        return nil
    }
}

extension View {
    /// 按快捷键表挂键盘快捷键；表里改了键，挂着的按钮跟着换。
    func shortcut(_ action: ShortcutAction) -> some View {
        let combo = ShortcutStore.shared.combo(action)
        return keyboardShortcut(combo.keyEquivalent, modifiers: combo.modifiers)
    }
}

/// 设置页里的改键框：点一下进入录入，按下新组合即保存；Esc 取消。冲突与保留键不保存，在下面一行说明原因。
/// 录入期间用本地事件监视器吃掉所有按键，免得 ⌘N 之类在录入时触发菜单。
struct ShortcutRecorderField: View {
    let action: ShortcutAction
    @Binding var recording: ShortcutAction?
    @Binding var problem: (ShortcutAction, String)?
    private let store = ShortcutStore.shared
    @State private var monitor: Any?

    var body: some View {
        let active = recording == action
        Button {
            if active { stop() } else { recording = action; problem = nil }
        } label: {
            Text(active ? String(localized: "按下新的快捷键") : store.display(action))
                .font(CaploFont.value)
                .foregroundStyle(active ? CaploColor.accent : CaploColor.textPrimary)
                .frame(minWidth: 72)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(CaploColor.textPrimary.opacity(active ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(active ? CaploColor.accent : CaploColor.separator, lineWidth: active ? 1.5 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(active ? "Esc 取消" : "点击录入")
        .accessibilityLabel("\(action.title)快捷键")
        .accessibilityValue(active ? String(localized: "正在录入") : store.display(action))
        .onChange(of: active, initial: true) { _, now in now ? start() : removeMonitor() }
        .onDisappear { if active { recording = nil }; removeMonitor() }
    }

    private func start() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { stop(); return }
        guard let combo = KeyCombo(event: event) else {
            problem = (action, String(localized: "方向键、回车、删除、Tab、Esc 与功能键不能设为快捷键")); return
        }
        if let reason = store.problem(assigning: combo, to: action) { problem = (action, reason); return }
        store.assign(combo, to: action)
        problem = nil
        stop()
    }

    private func stop() { recording = nil; removeMonitor() }
    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}

import AppKit
import Testing
@testable import CaploDesignSystem

/// 条目 → 原生菜单：勾选、禁用、说明行、分隔线、节标题、子菜单一一对应；动作对象随菜单项存活并能触发。
@MainActor @Test func popupMenuEntriesBecomeNativeItems() {
    var fired = 0
    let menu = MenuAnchor.makeMenu([
        .header("显示器"),
        .item("显示器 1", checked: true) { fired += 1 },
        .item("显示器 2") { fired += 10 },
        .separator,
        .text("麦克风模式 · 标准"),
        .item("禁用项", enabled: false, action: {}),
        .submenu("倒计时 · 3 秒", [.item("不倒计时", action: {}), .item("3 秒", checked: true, action: {})]),
    ])
    #expect(menu.items.count == 7 && !menu.autoenablesItems)
    #expect(menu.items[0].isSectionHeader && menu.items[0].title == "显示器")
    #expect(menu.items[1].state == .on && menu.items[1].isEnabled && menu.items[2].state == .off)
    #expect(menu.items[3].isSeparatorItem)
    #expect(menu.items[4].title == "麦克风模式 · 标准" && !menu.items[4].isEnabled && menu.items[4].action == nil)
    #expect(!menu.items[5].isEnabled)
    #expect(menu.items[6].submenu?.items.count == 2 && menu.items[6].submenu?.items[1].state == .on)
    for item in menu.items { (item.target as? MenuTarget)?.fire() }
    #expect(fired == 11)
}

/// 面板下拉的分组映射：组间分隔线，有标题的组带节标题。
@MainActor @Test func selectFieldSectionsMapToEntries() {
    let entries = SelectField.entries([
        SelectField.Section("显示", items: [SelectField.Item(id: "a", title: "A", checked: true, action: {})]),
        SelectField.Section(items: [SelectField.Item(id: "b", title: "B", action: {})]),
    ])
    let menu = MenuAnchor.makeMenu(entries)
    #expect(menu.items.count == 4 && menu.items[0].isSectionHeader && menu.items[1].state == .on && menu.items[2].isSeparatorItem && menu.items[3].title == "B")
}

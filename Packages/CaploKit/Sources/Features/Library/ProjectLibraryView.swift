import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers
import ProjectKit
import ExportKit
import CaploDesignSystem

struct LibraryEntry: Identifiable, Sendable {
    let url: URL
    let document: ProjectDocument
    var modifiedAt: Date = .distantPast
    var id: URL { url }
    var lastModified: Date { max(document.createdAt, modifiedAt) }
}

/// 项目中心只管理列表；编辑窗口独立持有工程，刷新列表不会替换正在编辑的会话。
@MainActor @Observable
final class ProjectLibraryModel {
    static let shared = ProjectLibraryModel()
    var entries: [LibraryEntry] = []
    var error: String?
    var loading = false

    func refresh() async {
        guard !loading else { return }
        loading = true
        let extra = UserDefaults.standard.stringArray(forKey: "externalProjects") ?? []
        let result = await Task.detached(priority: .utility) {
            var entries: [LibraryEntry] = []
            var issues: [String] = []
            let root = ProjectStorage.libraryURL
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let local = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            let urls = Set((local.filter { $0.pathExtension == "caplo" } + extra.map { URL(fileURLWithPath: $0) })
                .map { $0.resolvingSymlinksInPath().standardizedFileURL })
            for url in urls {
                do {
                    var document = try ProjectStorage.load(url)
                    if document.state == .recording {
                        // 活跃录制持有租约，跳过它；恢复过程内部仍会重新取得独占锁。
                        if let lease = try? ProjectLease(url: url) { withExtendedLifetime(lease) {} }
                        else { continue }
                        document = try ProjectStorage.recover(url)
                    }
                    let dates = ["manifest.json", "edits.json"].compactMap {
                        try? url.appendingPathComponent($0).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    }
                    entries.append(LibraryEntry(url: url, document: document, modifiedAt: dates.max() ?? document.createdAt))
                } catch { issues.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            }
            return (entries.sorted { $0.lastModified > $1.lastModified }, issues)
        }.value
        entries = result.0
        error = result.1.isEmpty ? nil : result.1.joined(separator: "\n")
        loading = false
    }

    func importProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(exportedAs: "com.caplo.project", conformingTo: .package)]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        VideoEditorWindow.shared.show(project: url)
    }

    static func remember(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: "externalProjects") ?? []
        if !paths.contains(url.path) { paths.append(url.path) }
        UserDefaults.standard.set(paths, forKey: "externalProjects")
    }

    static func forget(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: "externalProjects") ?? []
        paths.removeAll { $0 == url.path }
        UserDefaults.standard.set(paths, forKey: "externalProjects")
    }

    func rename(_ entry: LibraryEntry, to name: String) async -> Bool {
        do {
            try await Task.detached(priority: .utility) { try ProjectStorage.rename(entry.url, to: name) }.value
            await refresh()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    /// 复制整个工程包到项目库，名称加"副本"；正在编辑的工程也可复制（复制的是磁盘上的已保存状态）。
    func duplicate(_ entry: LibraryEntry) async {
        do {
            let name = entry.document.name + " 副本"
            try await Task.detached(priority: .utility) {
                let root = ProjectStorage.libraryURL
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let destination = root.appendingPathComponent(UUID().uuidString + ".caplo")
                try FileManager.default.copyItem(at: entry.url, to: destination)
                try? FileManager.default.removeItem(at: destination.appendingPathComponent("lease.lock"))
                try ProjectStorage.rename(destination, to: name)
            }.value
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    /// 移到废纸篓，可从访达恢复；正在编辑的工程跳过并提示。多个工程一次处理，只刷新一次列表。
    func trash(_ entries: [LibraryEntry]) async {
        var issues: [String] = []
        for entry in entries {
            if VideoEditorSessions.current?.entry.url == entry.url { issues.append("“\(entry.document.name)”正在编辑，请先关闭编辑器。"); continue }
            do {
                try await Task.detached(priority: .utility) { try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil) }.value
                Self.forget(entry.url)
            } catch { issues.append(error.localizedDescription) }
        }
        await refresh()
        if !issues.isEmpty { error = issues.joined(separator: "\n") }
    }
    func trash(_ entry: LibraryEntry) async { await trash([entry]) }
}

/// 独立项目中心：检索和管理已有录制，不在列表内部切换成编辑器。
public struct ProjectLibraryView: View {
    @State private var model: ProjectLibraryModel
    @State private var search = ""
    @State private var renaming: LibraryEntry?
    @State private var trashing: TrashRequest?
    @State private var newName = ""
    @State private var savingName = false
    /// 列表选择：单击选中，⌘ 加选，⇧ 连选，双击或回车打开，⌫ 删除选中。
    @State private var selection: Set<URL> = []
    @State private var selectionAnchor: URL?
    /// 窗口打开时焦点在列表而不是搜索框：⌫ / 回车 / ⌘A 直接作用于项目，⌘F 才进搜索，Esc 回到列表。
    @SwiftUI.FocusState private var focus: LibraryFocus?
    private let previewOnly: Bool

    private enum LibraryFocus: Hashable { case search, list }

    private struct TrashRequest: Identifiable {
        let entries: [LibraryEntry]
        var id: String { entries.map(\.url.path).joined(separator: "\n") }
    }

    /// `previewError`：预览时直接显示底部提示条，供离线出图核对样式。
    public init(previewOnly: Bool = false, previewProjectURL: URL? = nil, previewError: String? = nil) {
        self.previewOnly = previewOnly
        let model = previewOnly ? ProjectLibraryModel() : .shared
        if let previewProjectURL, let document = try? ProjectStorage.load(previewProjectURL) {
            model.entries = [LibraryEntry(url: previewProjectURL, document: document)]
        }
        if previewOnly, let previewError { model.error = previewError }
        _model = State(initialValue: model)
    }

    private var filtered: [LibraryEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? model.entries : model.entries.filter { $0.document.name.localizedStandardContains(query) }
    }

    /// 列表按录制日期分组、组内按录制时间倒序：名字里的时间和列表顺序一致，"最近修改"退到行内次要位置。
    private var grouped: [(title: String, entries: [LibraryEntry])] {
        let calendar = Calendar.current
        let sorted = filtered.sorted { $0.document.createdAt > $1.document.createdAt }
        var result: [(title: String, entries: [LibraryEntry])] = []
        for entry in sorted {
            let day = calendar.startOfDay(for: entry.document.createdAt)
            let title = Self.groupTitle(for: day, calendar: calendar)
            if let index = result.firstIndex(where: { $0.title == title }) { result[index].entries.append(entry) }
            else { result.append((title, [entry])) }
        }
        return result
    }

    /// 分组标题不依赖系统区域设置，统一写成"9 月 7 日"；跨年才带年份。
    static func groupTitle(for day: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        var date = "\(parts.month ?? 1) 月 \(parts.day ?? 1) 日"
        if !calendar.isDate(day, equalTo: now, toGranularity: .year) { date = "\(parts.year ?? 0) 年 " + date }
        if calendar.isDateInToday(day) { return "今天 · " + date }
        if calendar.isDateInYesterday(day) { return "昨天 · " + date }
        return date
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 与编辑器同款 52 点顶栏：左侧为红黄绿预留位，标题与计数、搜索、刷新与两个主动作都在这一行。
            HStack(spacing: CaploMetrics.Spacing.m) {
                Spacer().frame(width: CaploMetrics.trafficLightsInset - CaploMetrics.Spacing.l)
                VStack(alignment: .leading, spacing: 1) {
                    Text("项目中心").font(CaploFont.bodyMedium).foregroundStyle(CaploColor.textPrimary)
                    Text(selection.isEmpty ? "\(model.entries.count) 个项目" : "已选 \(selection.count) / \(filtered.count)")
                        .font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
                }
                HStack(spacing: CaploMetrics.Spacing.xs + 2) {
                    Image(systemName: "magnifyingglass").foregroundStyle(CaploColor.textTertiary)
                    // 关掉系统焦点环：窗口刚打开时 AppKit 会先把键盘焦点给第一个文本框，再由 SwiftUI 移到列表，
                    // 那一帧的系统焦点环就是"一闪而逝的框"。焦点状态改由下面自绘的强调色描边表示。
                    TextField("搜索项目", text: $search).textFieldStyle(.plain).font(CaploFont.body)
                        .foregroundStyle(CaploColor.textPrimary)
                        .environment(\.colorScheme, .dark)
                        .focusEffectDisabled()
                        .focused($focus, equals: .search)
                        .onExitCommand { focus = .list }
                        .onSubmit { focus = .list }
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(CaploColor.textTertiary).accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 10).frame(width: 240, height: CaploMetrics.ControlHeight.medium)
                .caploMaterial(.raised, cornerRadius: CaploMetrics.Radius.control)
                .overlay {
                    if focus == .search {
                        RoundedRectangle(cornerRadius: CaploMetrics.Radius.control, style: .continuous).strokeBorder(CaploColor.accent.opacity(0.9), lineWidth: 1.5)
                    }
                }
                Spacer()
                if !selection.isEmpty {
                    // 批量动作只用图标，数量在标题下方的"已选 N / M"里；文字按钮会把顶栏挤得很满。
                    Button { requestTrash(selectedEntries) } label: { Image(systemName: "trash").foregroundStyle(CaploColor.record) }
                        .buttonStyle(StudioIconButtonStyle())
                        .help("删除选中的 \(selection.count) 项 ⌫").accessibilityLabel("删除选中的 \(selection.count) 项")
                    Button { selection.removeAll() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(StudioIconButtonStyle()).help("取消选择 · 全选 ⌘A").accessibilityLabel("取消选择")
                }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(StudioIconButtonStyle()).help("刷新项目").accessibilityLabel("刷新项目")
                    .disabled(model.loading || previewOnly)
                Button { model.importProject() } label: { Label("打开工程", systemImage: "folder") }.buttonStyle(StudioButtonStyle(.secondary, size: .large))
                Button { StudioWindows.showRecorder() } label: { Label("新建录制", systemImage: "plus") }.buttonStyle(StudioButtonStyle(.primary, size: .large))
            }
            .padding(.horizontal, CaploMetrics.Spacing.l).frame(height: CaploMetrics.titleBarHeight)
            .background(CaploMaterialBackground(.panel))
            StudioDivider()
            if model.loading && model.entries.isEmpty {
                ProgressView("正在载入项目…").environment(\.colorScheme, .dark)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                VStack(spacing: CaploMetrics.Spacing.m) {
                    Image(systemName: search.isEmpty ? "film.stack" : "magnifyingglass").font(.system(size: 34, weight: .light)).foregroundStyle(CaploColor.textTertiary)
                    Text(search.isEmpty ? "还没有录制项目" : "没有找到匹配项目").font(CaploFont.panelTitle).foregroundStyle(CaploColor.textPrimary)
                    Text(search.isEmpty ? "完成录制后，项目会自动保存在这里。" : "试试其他名称。").font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
                    if search.isEmpty {
                        Button("开始录制") { StudioWindows.showRecorder() }.buttonStyle(StudioButtonStyle(.primary, size: .large)).padding(.top, CaploMetrics.Spacing.xs)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // 行之间留 6 点：悬停 / 选中的圆角底彼此分开，不再上下贴在一起；分隔线由留白代替。
                    LazyVStack(spacing: 6) {
                        ForEach(grouped, id: \.title) { group in
                            Text(group.title).font(CaploFont.sectionTitle).foregroundStyle(CaploColor.textTertiary)
                                .padding(.horizontal, CaploMetrics.Spacing.m).padding(.top, CaploMetrics.Spacing.m).padding(.bottom, CaploMetrics.Spacing.xs)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityAddTraits(.isHeader)
                        ForEach(group.entries) { entry in row(for: entry) }
                        }
                    }.padding(.horizontal, CaploMetrics.Spacing.l).padding(.bottom, CaploMetrics.Spacing.s)
                }
                .contentShape(Rectangle())
                .focusable().focusEffectDisabled().focused($focus, equals: .list)
                .onTapGesture { selection.removeAll(); focus = .list }
                .onKeyPress("f", phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    focus = .search; return .handled
                }
                .onDeleteCommand { requestTrash(selectedEntries) }
                .onKeyPress(.return) {
                    guard let url = selection.first, selection.count == 1 else { return .ignored }
                    VideoEditorWindow.shared.show(project: url); return .handled
                }
                .onKeyPress("a", phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    selection = Set(filtered.map(\.url)); return .handled
                }
            }
            if let error = model.error {
                // 图标、文字与右侧 24 点高的关闭按钮按中线对齐；原先顶对齐会让单行文字比按钮中线高出几点。
                HStack(alignment: .center, spacing: CaploMetrics.Spacing.s) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 13, weight: .medium)).foregroundStyle(CaploColor.warning)
                    Text(error).font(CaploFont.caption).textSelection(.enabled).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(StudioIconButtonStyle(size: .small)).accessibilityLabel("关闭提示")
                }.padding(.horizontal, CaploMetrics.Spacing.m).padding(.vertical, CaploMetrics.Spacing.s).background(CaploColor.warning.opacity(0.1))
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(CaploMaterialBackground(.window)).tint(CaploColor.accent)
        .foregroundStyle(CaploColor.textPrimary)
        .preferredColorScheme(.dark)
        .task { if !previewOnly { await model.refresh() } }
        .sheet(item: $renaming) { entry in
            VStack(alignment: .leading, spacing: CaploMetrics.Spacing.l) {
                Text("重命名项目").font(CaploFont.panelTitle)
                TextField("项目名称", text: $newName).textFieldStyle(.plain)
                    .foregroundStyle(CaploColor.textPrimary)
                    .environment(\.colorScheme, .dark)
                    .padding(.horizontal, 10).frame(height: CaploMetrics.ControlHeight.large)
                    .caploMaterial(.raised, cornerRadius: CaploMetrics.Radius.control)
                HStack {
                    Spacer()
                    Button("取消") { renaming = nil }.buttonStyle(StudioButtonStyle(.secondary)).keyboardShortcut(.cancelAction).disabled(savingName)
                    Button("保存") {
                        savingName = true
                        Task {
                            if await model.rename(entry, to: newName) { renaming = nil }
                            savingName = false
                        }
                    }.buttonStyle(StudioButtonStyle(.primary)).keyboardShortcut(.defaultAction).disabled(savingName || newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error = model.error { Text(error).font(CaploFont.caption).foregroundStyle(CaploColor.warning) }
            }.padding(CaploMetrics.Spacing.xl).frame(width: 360)
                .foregroundStyle(CaploColor.textPrimary)
                // 独立弹层拥有自己的采样层，清除系统默认底色，内部输入框仅叠加轻量表面。
                .background(CaploMaterialBackground(.window))
                .presentationBackground(.clear)
        }
        .sheet(item: $trashing) { request in
            StudioConfirmSheet(
                title: request.entries.count == 1 ? "删除到废纸篓？" : "删除 \(request.entries.count) 个工程？",
                message: trashMessage(request.entries),
                confirmTitle: request.entries.count == 1 ? "删除" : "删除 \(request.entries.count) 项", danger: true,
                confirm: {
                    let entries = request.entries
                    trashing = nil; selection.subtract(entries.map(\.url))
                    Task { await model.trash(entries) }
                }, cancel: { trashing = nil })
        }
        .onChange(of: model.entries.map(\.url)) { _, urls in selection.formIntersection(urls) }
        .defaultFocus($focus, .list)
        .onAppear { focus = .list }
    }

    private var selectedEntries: [LibraryEntry] { filtered.filter { selection.contains($0.url) } }

    private func row(for entry: LibraryEntry) -> some View {
        let editing = VideoEditorSessions.current?.entry.url == entry.url
        let inSelection = selection.contains(entry.url)
        let deleteTitle = inSelection && selection.count > 1 ? "删除选中的 \(selection.count) 项…" : "删除到废纸篓…"
        return ProjectRow(entry: entry, selected: inSelection, selecting: !selection.isEmpty,
                          open: { VideoEditorWindow.shared.show(project: entry.url) },
                          select: { modifiers in select(entry, modifiers: modifiers) },
                          toggle: { toggle(entry) }) {
            Button("打开编辑器") { VideoEditorWindow.shared.show(project: entry.url) }
            Button("重命名…") { newName = entry.document.name; renaming = entry }.disabled(editing)
            Button("复制") { Task { await model.duplicate(entry) } }
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            Divider()
            Button(deleteTitle, role: .destructive) { requestTrash(inSelection ? selectedEntries : [entry]) }
        }
    }

    private func trashMessage(_ entries: [LibraryEntry]) -> String {
        let names = entries.map { "“\($0.document.name)”" }
        let subject = entries.count <= 3 ? names.joined(separator: "、") : names.prefix(3).joined(separator: "、") + " 等 \(entries.count) 个工程"
        return subject + "会移到废纸篓，可从访达恢复。"
    }

    private func requestTrash(_ entries: [LibraryEntry]) {
        let deletable = entries.filter { VideoEditorSessions.current?.entry.url != $0.url }
        guard !deletable.isEmpty else { if !entries.isEmpty { model.error = "工程正在编辑，请先关闭编辑器。" }; return }
        trashing = TrashRequest(entries: deletable)
    }

    /// 行首圆圈：不用修饰键的多选入口。
    private func toggle(_ entry: LibraryEntry) {
        if selection.contains(entry.url) { selection.remove(entry.url) } else { selection.insert(entry.url) }
        selectionAnchor = entry.url
    }

    /// 单击选中；⌘ 切换；⇧ 从锚点连选（按当前列表顺序）。
    private func select(_ entry: LibraryEntry, modifiers: NSEvent.ModifierFlags) {
        focus = .list
        let order = grouped.flatMap(\.entries).map(\.url)
        if modifiers.contains(.shift), let anchor = selectionAnchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: entry.url) {
            selection.formUnion(order[min(from, to)...max(from, to)])
        } else if modifiers.contains(.command) {
            if selection.contains(entry.url) { selection.remove(entry.url) } else { selection.insert(entry.url) }
            selectionAnchor = entry.url
        } else {
            selection = [entry.url]; selectionAnchor = entry.url
        }
    }
}

/// 项目行：112×63 缩略图压时长角标，标题一行，元信息一行，右端"…"菜单；行高 80。
/// 整行响应悬停（3.5% 亮底）与选中（强调软底 + 描边），单击选中、双击打开；组标题在行外不受影响。
private enum ProjectRowMetrics {
    static let thumbnailSize = CGSize(width: 112, height: 63)
    static let height: CGFloat = 80
    /// 行首选择圆圈的槽位：始终占位，悬停或进入多选时才显示，内容不会左右跳。
    static let checkSlot: CGFloat = 22
}

private struct ProjectRow<Actions: View>: View {
    let entry: LibraryEntry
    let selected: Bool
    /// 列表里已有任何选择：所有行常显圆圈，方便继续勾选。
    let selecting: Bool
    let open: () -> Void
    let select: (NSEvent.ModifierFlags) -> Void
    let toggle: () -> Void
    @ViewBuilder let actions: Actions
    @State private var thumbnail: NSImage?
    @State private var hovered = false

    /// 录制后没再改过就不重复显示修改时间；同一天只显示时刻，否则显示日期。
    private var modified: String? {
        let calendar = Calendar.current, date = entry.lastModified
        guard date.timeIntervalSince(entry.document.createdAt) > 60 else { return nil }
        if calendar.isDate(date, inSameDayAs: entry.document.createdAt) { return "修改于 " + date.formatted(date: .omitted, time: .shortened) }
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "修改于 \(parts.month ?? 1) 月 \(parts.day ?? 1) 日"
    }

    var body: some View {
        HStack(spacing: CaploMetrics.Spacing.l) {
            // 鼠标可点的多选入口；与整行的单击 / 双击互不干扰。
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(selected ? CaploColor.accent : CaploColor.textTertiary)
                .frame(width: ProjectRowMetrics.checkSlot, height: ProjectRowMetrics.checkSlot)
                .opacity(selected || selecting || hovered ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture { toggle() }
                .accessibilityLabel(selected ? "取消选择" : "选择")
                .accessibilityAddTraits(.isButton)
                .padding(.trailing, CaploMetrics.Spacing.s - CaploMetrics.Spacing.l)
            ZStack {
                CaploColor.surfaceCanvasWell
                if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFill() }
                else { Image(systemName: "film").font(.title2).foregroundStyle(CaploColor.textTertiary) }
            }
            .frame(width: ProjectRowMetrics.thumbnailSize.width, height: ProjectRowMetrics.thumbnailSize.height)
            .clipShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control + 2))
            .overlay(alignment: .bottomTrailing) {
                Text(timecode(entry.document.duration)).font(CaploFont.caption.monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .padding(5)
            }
            VStack(alignment: .leading, spacing: CaploMetrics.Spacing.xs + 2) {
                Text(entry.document.name).font(CaploFont.bodyMedium).foregroundStyle(CaploColor.textPrimary).lineLimit(1)
                HStack(spacing: CaploMetrics.Spacing.m) {
                    Text("录制于 " + entry.document.createdAt.formatted(date: .omitted, time: .shortened)).font(CaploFont.caption)
                    if let modified { Text(modified).font(CaploFont.caption) }
                    if entry.document.state == .recovered { Text("已恢复").font(CaploFont.caption).foregroundStyle(CaploColor.warning) }
                }.foregroundStyle(CaploColor.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu { actions } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(CaploColor.textSecondary)
                .environment(\.colorScheme, .dark)
                .help("项目操作").accessibilityLabel("\(entry.document.name)的操作")
                .opacity(hovered || selected ? 1 : 0.55)
        }
        .padding(.horizontal, CaploMetrics.Spacing.m).frame(height: ProjectRowMetrics.height)
        .background(selected ? CaploColor.accentSoft : CaploColor.textPrimary.opacity(hovered ? 0.035 : 0), in: RoundedRectangle(cornerRadius: CaploMetrics.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: CaploMetrics.Radius.card).strokeBorder(CaploColor.accent.opacity(selected ? 0.35 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: CaploMetrics.Radius.card))
        .onHover { hovered = $0 }
        // 单击立即选中，不等双击判定超时（否则每次点击都要停顿三百毫秒才高亮）；双击在选中之后再打开。
        .onTapGesture { select(NSEvent.modifierFlags) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { open() })
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "打开编辑器") { open() }
        .task(id: entry.url) {
            if let image = try? await ProjectMedia.thumbnail(url: entry.url, document: entry.document) {
                guard !Task.isCancelled else { return }
                thumbnail = Self.downscaled(image)
            }
        }
    }

    /// 缩略图按 2× 显示尺寸重采样一次：原图是整帧截图，选择状态变化时整列重画会明显卡顿。
    private static func downscaled(_ image: CGImage) -> NSImage {
        let scale = 2.0, targetWidth = ProjectRowMetrics.thumbnailSize.width * scale
        let ratio = Double(image.height) / Double(max(1, image.width))
        let size = CGSize(width: targetWidth, height: max(1, (targetWidth * ratio).rounded()))
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return NSImage(cgImage: image, size: .zero)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let small = context.makeImage() else { return NSImage(cgImage: image, size: .zero) }
        return NSImage(cgImage: small, size: CGSize(width: size.width / scale, height: size.height / scale))
    }
}

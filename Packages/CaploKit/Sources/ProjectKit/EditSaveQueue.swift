import Foundation
import os
import EditingCore

/// 编辑会话的存盘队列：校验、编码与写盘放到后台串行队列，不占主线程。
///
/// 以前每次提交都在主线程同步保存（校验 + 编码 + 原子写，还把旧文件读两遍），
/// 带长运镜路径的工程拖完一个滑块要卡上几十到几百毫秒。现在：
/// - **合并**：最后一次提交后静候 `quietInterval` 再写；一直有提交进来（方向键连按、连续点选）时最多拖 `maximumDelay`
///   也要写一次。中间的版本马上会被覆盖，写了也白写——两小时的工程编码一次约 80 毫秒，逐次写会把一个核占满；
/// - **跳过**：要写的内容与上次成功写下的完全相同（撤销回到刚存过的状态、改了又改回）就不再编码写盘；
/// - **落盘时机不变**：关窗、退出、重试前 `flush()` 跳过等待、同步写完并拿到结果，"保存失败不能关窗"这条规则不变。
///   合并窗口只意味着崩溃时最多丢最后一秒内的改动。
public final class EditSaveQueue: @unchecked Sendable {
    /// 一次写盘的结果。`number` 递增：主线程上排着的旧回调可能晚于 `flush()` 的结果到达，按它丢掉过期的。
    public struct Outcome: Equatable, Sendable {
        public let number: Int
        public let error: String?
    }

    /// 最后一次提交之后静候多久再写。
    public static let quietInterval = 0.25
    /// 一串连续提交里第一份最多等多久就必须写下。
    public static let maximumDelay = 1.0

    private let url: URL
    private let document: ProjectDocument
    private let queue = DispatchQueue(label: "com.caplo.edit-save", qos: .userInitiated)
    private struct State {
        var pending: VideoEdit?
        var completion: (@MainActor @Sendable (Outcome) -> Void)?
        /// 这一串提交里第一份与最后一份进来的时刻（`DispatchTime.uptimeNanoseconds`）。
        var firstSubmit: UInt64 = 0
        var lastSubmit: UInt64 = 0
        /// 是否已有一个延时写盘排在队列上；它到点时再按两个时刻决定写还是继续等。
        var scheduled = false
        var last = Outcome(number: 0, error: nil)
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// 只在存盘队列上读写。
    private var onDisk: EditStorage.FileVersions?
    /// 上次成功写下的内容；只在存盘队列上读写。写失败就清掉，下次一定重写。
    private var written: VideoEdit?

    /// `written`：调用方刚写下的那份（打开工程时的首次落盘），紧接着的同样内容不必再写一遍。
    public init(url: URL, document: ProjectDocument, onDisk: EditStorage.FileVersions? = nil, written: VideoEdit? = nil) {
        self.url = url; self.document = document; self.onDisk = onDisk; self.written = written
    }

    /// 排队保存这一份。`completion` 在主线程回调写盘结果；被后来的提交覆盖掉的那份不单独回调。
    public func save(_ edit: VideoEdit, completion: @escaping @MainActor @Sendable (Outcome) -> Void) {
        let now = DispatchTime.now().uptimeNanoseconds
        let schedule = state.withLock { state -> Bool in
            if state.pending == nil { state.firstSubmit = now }
            state.pending = edit; state.completion = completion; state.lastSubmit = now
            defer { state.scheduled = true }
            return !state.scheduled
        }
        if schedule { queue.asyncAfter(deadline: .now() + Self.quietInterval) { [self] in tick() } }
    }

    /// 跳过合并等待，同步写完排着的那份，返回最后一次写盘的结果。只在关窗、退出、重试时调用。
    @discardableResult
    public func flush() -> Outcome {
        queue.sync { writePending() }
        return state.withLock { $0.last }
    }

    /// 延时到点：静候期已过或已拖满上限就写，否则按剩余时间再约一次。
    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let wait = state.withLock { state -> Double? in
            guard state.pending != nil else { state.scheduled = false; return nil }
            let quiet = Double(state.lastSubmit) / 1e9 + Self.quietInterval
            let limit = Double(state.firstSubmit) / 1e9 + Self.maximumDelay
            let remaining = min(quiet, limit) - Double(now) / 1e9
            if remaining > 0.001 { return remaining }
            state.scheduled = false
            return nil
        }
        if let wait { queue.asyncAfter(deadline: .now() + wait) { [self] in tick() }; return }
        writePending()
    }

    /// 只在存盘队列上调用。
    private func writePending() {
        let job = state.withLock { state -> (VideoEdit, @MainActor @Sendable (Outcome) -> Void)? in
            defer { state.pending = nil; state.completion = nil }
            guard let edit = state.pending, let completion = state.completion else { return nil }
            return (edit, completion)
        }
        guard let (edit, completion) = job else { return }
        let message: String?
        if edit == written { message = nil }
        else {
            do { try EditStorage.save(edit, in: url, document: document, onDisk: &onDisk); written = edit; message = nil }
            catch { message = error.localizedDescription; onDisk = nil; written = nil }
        }
        let outcome = state.withLock { state -> Outcome in
            state.last = Outcome(number: state.last.number + 1, error: message)
            return state.last
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { completion(outcome) } }
    }
}

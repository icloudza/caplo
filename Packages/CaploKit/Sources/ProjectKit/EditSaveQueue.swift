import Foundation
import os
import EditingCore

/// 编辑会话的存盘队列：校验、编码与写盘放到后台串行队列，不占主线程。
///
/// 以前每次提交都在主线程同步保存（校验 + 编码 + 原子写，还把旧文件读两遍），
/// 带长运镜路径的工程拖完一个滑块要卡上几十到几百毫秒。现在连续的提交只写最后一份——
/// 中间的版本马上会被覆盖，写了也白写。关窗、退出前用 `flush()` 同步等最后一份落盘并拿到结果，
/// 所以"保存失败不能关窗"这条规则不变。
public final class EditSaveQueue: @unchecked Sendable {
    /// 一次写盘的结果。`number` 递增：主线程上排着的旧回调可能晚于 `flush()` 的结果到达，按它丢掉过期的。
    public struct Outcome: Equatable, Sendable {
        public let number: Int
        public let error: String?
    }

    private let url: URL
    private let document: ProjectDocument
    private let queue = DispatchQueue(label: "com.caplo.edit-save", qos: .userInitiated)
    private struct State { var pending: VideoEdit?; var last = Outcome(number: 0, error: nil) }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// 只在存盘队列上读写。
    private var onDisk: EditStorage.FileVersions?

    public init(url: URL, document: ProjectDocument, onDisk: EditStorage.FileVersions? = nil) {
        self.url = url; self.document = document; self.onDisk = onDisk
    }

    /// 排队保存这一份。`completion` 在主线程回调写盘结果；被后来的提交覆盖掉的那份不单独回调。
    public func save(_ edit: VideoEdit, completion: @escaping @MainActor @Sendable (Outcome) -> Void) {
        let schedule = state.withLock { state -> Bool in
            defer { state.pending = edit }
            return state.pending == nil
        }
        guard schedule else { return }
        queue.async { [self] in drain(completion) }
    }

    /// 同步等到排队的保存全部落盘，返回最后一次写盘的结果。只在关窗、退出、重试时调用。
    @discardableResult
    public func flush() -> Outcome {
        queue.sync {}
        return state.withLock { $0.last }
    }

    private func drain(_ completion: @escaping @MainActor @Sendable (Outcome) -> Void) {
        while let edit = state.withLock({ state -> VideoEdit? in defer { state.pending = nil }; return state.pending }) {
            let message: String?
            do { try EditStorage.save(edit, in: url, document: document, onDisk: &onDisk); message = nil }
            catch { message = error.localizedDescription; onDisk = nil }
            let outcome = state.withLock { state -> Outcome in
                state.last = Outcome(number: state.last.number + 1, error: message)
                return state.last
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(outcome) } }
        }
    }
}

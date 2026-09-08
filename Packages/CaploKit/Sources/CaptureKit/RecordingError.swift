import Foundation

/// 录制错误统一提供中文说明，供主窗口、浮窗和项目库展示。
public enum RecordingError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}

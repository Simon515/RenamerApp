import Foundation
import os

/// 集中定义按子系统划分的 Logger。
///
/// 日志中**不得**记录 API Key、文件内容或云端返回全文；仅记录错误描述与非敏感计数。
enum Log {
    private static let subsystem = "com.renamer"

    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    static let organizer = Logger(subsystem: subsystem, category: "organizer")
    static let rollback = Logger(subsystem: subsystem, category: "rollback")
    static let settings = Logger(subsystem: subsystem, category: "settings")
}

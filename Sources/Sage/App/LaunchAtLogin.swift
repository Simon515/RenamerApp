import Foundation
import ServiceManagement

/// 登录启动开关封装（SMAppService，macOS 13+）。
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // 命令行/未签名环境下可能失败；不崩溃，仅忽略（GUI .app 内可用）
            NSLog("LaunchAtLogin 设置失败：\(error.localizedDescription)")
        }
    }
}

import Foundation

/// 菜单栏控制器占位实现。
/// 后续将负责应用启动后菜单栏图标、状态管理及快捷操作入口。
@MainActor
final class MenuBarController: ObservableObject {
    static let shared = MenuBarController()

    private init() {}
}

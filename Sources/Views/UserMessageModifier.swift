import SwiftUI

/// 面向用户的一次性提示，承载成功或错误消息，供统一的 alert 展示。
struct UserMessage: Identifiable, Sendable {
    let id = UUID()
    let text: String
    let isError: Bool

    static func error(_ text: String) -> UserMessage { UserMessage(text: text, isError: true) }
    static func success(_ text: String) -> UserMessage { UserMessage(text: text, isError: false) }
}

private struct UserMessageAlert: ViewModifier {
    @Binding var message: UserMessage?

    func body(content: Content) -> some View {
        content.alert(
            message?.isError == true ? "出错了" : "提示",
            isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            ),
            presenting: message
        ) { _ in
            Button("确定") { message = nil }
        } message: { message in
            Text(message.text)
        }
    }
}

extension View {
    /// 以统一样式展示 `UserMessage` 提示；消息为 nil 时不显示。
    func userMessageAlert(_ message: Binding<UserMessage?>) -> some View {
        modifier(UserMessageAlert(message: message))
    }
}

import Foundation

/// 云端 AI 服务配置。
struct CloudConfiguration: Sendable {
    let baseURL: URL
    let apiKey: String
    let model: String
}

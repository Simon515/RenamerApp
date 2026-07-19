import Foundation

// Sage headless 冒烟入口。GUI 与菜单栏形态在第 4 份计划实现。
let support = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Sage", isDirectory: true)
try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
print("Sage core assembled at \(support.path)")

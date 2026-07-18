// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Renamer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Renamer", targets: ["Renamer"])
    ],
    targets: [
        .executableTarget(
            name: "Renamer",
            path: "Sources",
            // 排除新增的 Sage 目录，避免与 Sage 目标源码路径重叠；Renamer 实际编译内容不变
            exclude: ["Sage"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "RenamerTests",
            dependencies: ["Renamer"],
            path: "Tests/RenamerTests"
        ),
        .executableTarget(
            name: "Sage",
            path: "Sources/Sage",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "SageTests",
            dependencies: ["Sage"],
            path: "Tests/SageTests"
        )
    ]
)

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
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "RenamerTests",
            dependencies: ["Renamer"],
            path: "Tests/RenamerTests"
        )
    ]
)

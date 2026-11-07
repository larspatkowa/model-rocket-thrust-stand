// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ThrustStandStudio",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ThrustStandStudio", targets: ["ThrustStandStudio"])
    ],
    targets: [
        .executableTarget(
            name: "ThrustStandStudio",
            path: "Sources/ThrustStandStudio"
        ),
        .testTarget(
            name: "ThrustStandStudioTests",
            dependencies: ["ThrustStandStudio"],
            path: "Tests/ThrustStandStudioTests"
        )
    ]
)

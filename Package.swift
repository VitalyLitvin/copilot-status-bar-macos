// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopilotStatusbar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "copilot-statusbar", targets: ["CopilotStatusbar"])
    ],
    targets: [
        .executableTarget(
            name: "CopilotStatusbar",
            path: "Sources/CopilotStatusbar"
        )
    ]
)

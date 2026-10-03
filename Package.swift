// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "LLMProbe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LLMProbeCore", targets: ["LLMProbeCore"]),
        .executable(name: "llmprobe", targets: ["llmprobe"]),
        .executable(name: "LLMProbeApp", targets: ["LLMProbeApp"]),
    ],
    targets: [
        .target(
            name: "LLMProbeCore",
            path: "Sources/LLMProbeCore",
            swiftSettings: v5
        ),
        .executableTarget(
            name: "llmprobe",
            dependencies: ["LLMProbeCore"],
            path: "Sources/llmprobe",
            swiftSettings: v5
        ),
        .executableTarget(
            name: "LLMProbeApp",
            dependencies: ["LLMProbeCore"],
            path: "Sources/LLMProbeApp",
            swiftSettings: v5
        ),
        .testTarget(
            name: "LLMProbeCoreTests",
            dependencies: ["LLMProbeCore"],
            path: "Tests/LLMProbeCoreTests",
            swiftSettings: v5
        ),
    ]
)

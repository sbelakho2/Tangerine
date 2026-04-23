// swift-tools-version: 6.0
import PackageDescription

#if os(macOS)
let platformList: [SupportedPlatform] = [.macOS(.v14)]
#else
let platformList: [SupportedPlatform] = []
#endif

let package = Package(
    name: "TangerineStage0",
    platforms: platformList,
    products: [
        .executable(name: "tg_stage0", targets: ["TangerineCLI"]),
        .library(name: "TangerineCompiler", targets: ["TangerineCompiler"]),
    ],
    targets: [
        .target(
            name: "TangerineCompiler",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TangerineCLI",
            dependencies: ["TangerineCompiler"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TangerineTestRunner",
            dependencies: ["TangerineCompiler"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

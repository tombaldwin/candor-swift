// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "candor-swift",
    platforms: [.macOS(.v13)],
    dependencies: [
        // The parsing layer — SwiftSyntax is to this engine what `syn` is to candor-scan:
        // syntactic, no build of the target required.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "candor-swift",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            // The agent contract rides in the bundle so `--agents` always describes THIS build.
            resources: [.copy("AGENTS.md")]
        ),
    ]
)

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
            ]
            // The agent contract is EMBEDDED as a Swift constant (AgentsDoc.swift, generated from
            // AGENTS.md by gen-agents-doc.py) rather than a bundle resource, so `--agents` survives
            // a binary copied out of .build (where Bundle.module would fatalError). smoke.sh gates
            // drift by diffing the served contract against AGENTS.md.
        ),
    ]
)

// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run23", dependencies: [.package(path: "../App23")],
    targets: [.executableTarget(name: "Run23", dependencies: [.product(name: "Feat23", package: "App23")])])

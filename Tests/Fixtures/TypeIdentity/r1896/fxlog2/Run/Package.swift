// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run", dependencies: [.package(path: "../App"), .package(path: "../swift-log")],
    targets: [.executableTarget(name: "Run", dependencies: [.product(name: "App", package: "App"), .product(name: "Logging", package: "swift-log")])])

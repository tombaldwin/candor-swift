// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run", dependencies: [.package(path: "../Guess"), .package(path: "../App")],
    targets: [.executableTarget(name: "Run", dependencies: [.product(name: "Guess", package: "Guess"), .product(name: "App", package: "App")])])

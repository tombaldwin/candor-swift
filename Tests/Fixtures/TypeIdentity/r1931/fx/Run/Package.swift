// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run", dependencies: [.package(path: "../App"), .package(path: "../Guess")],
    targets: [.executableTarget(name: "Run", dependencies: [.product(name: "App", package: "App")])])

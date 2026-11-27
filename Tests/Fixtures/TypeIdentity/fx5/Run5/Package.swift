// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run5", dependencies: [.package(path: "../App5")],
    targets: [.executableTarget(name: "Run5", dependencies: [.product(name: "Feature", package: "App5")])])

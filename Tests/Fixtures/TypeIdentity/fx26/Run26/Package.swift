// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run26", dependencies: [.package(path: "../App26")],
    targets: [.executableTarget(name: "Run26", dependencies: [.product(name: "Feat26", package: "App26")])])

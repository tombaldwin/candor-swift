// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run24", dependencies: [.package(path: "../App24")],
    targets: [.executableTarget(name: "Run24", dependencies: [.product(name: "Feat24", package: "App24")])])

// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run22", dependencies: [.package(path: "../App22")],
    targets: [.executableTarget(name: "Run22", dependencies: [.product(name: "Feature22", package: "App22")])])

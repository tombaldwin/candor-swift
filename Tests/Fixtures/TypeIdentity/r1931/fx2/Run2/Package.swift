// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run2", dependencies: [.package(path: "../App2")],
    targets: [.executableTarget(name: "Run2", dependencies: [.product(name: "Feature", package: "App2")])])

// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run3", dependencies: [.package(path: "../App3")],
    targets: [.executableTarget(name: "Run3", dependencies: [.product(name: "Feature", package: "App3")])])

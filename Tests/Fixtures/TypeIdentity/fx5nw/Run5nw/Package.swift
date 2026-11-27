// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run5nw", dependencies: [.package(path: "../App5nw")],
    targets: [.executableTarget(name: "Run5nw", dependencies: [.product(name: "Feature", package: "App5nw")])])

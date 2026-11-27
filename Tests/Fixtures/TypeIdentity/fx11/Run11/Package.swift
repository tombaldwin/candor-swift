// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run11", dependencies: [.package(path: "../App11")],
    targets: [.executableTarget(name: "Run11", dependencies: [.product(name: "Feature11", package: "App11"), .product(name: "Feature11mi", package: "App11")])])

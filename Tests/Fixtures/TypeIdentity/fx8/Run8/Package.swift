// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run8", dependencies: [.package(path: "../App8")],
    targets: [.executableTarget(name: "Run8", dependencies: [.product(name: "Feature8", package: "App8")])])

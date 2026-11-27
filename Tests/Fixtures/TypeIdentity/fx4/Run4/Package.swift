// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run4", dependencies: [.package(path: "../App4")],
    targets: [.executableTarget(name: "Run4", dependencies: [.product(name: "Feature", package: "App4")])])

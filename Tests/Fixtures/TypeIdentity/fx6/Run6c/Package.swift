// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run6c", dependencies: [.package(path: "../Pkg6c")],
    targets: [.executableTarget(name: "Run6c", dependencies: [.product(name: "ToolA", package: "Pkg6c"), .product(name: "ToolB", package: "Pkg6c")])])

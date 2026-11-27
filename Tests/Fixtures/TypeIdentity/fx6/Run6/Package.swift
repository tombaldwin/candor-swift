// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run6", dependencies: [.package(path: "../Pkg6")],
    targets: [.executableTarget(name: "Run6", dependencies: [.product(name: "ToolA", package: "Pkg6"), .product(name: "ToolB", package: "Pkg6"), .product(name: "ToolC", package: "Pkg6")])])

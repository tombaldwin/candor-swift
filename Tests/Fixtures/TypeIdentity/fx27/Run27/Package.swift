// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run27", dependencies: [.package(path: "../Pkg27")],
    targets: [.executableTarget(name: "Run27", dependencies: [.product(name: "Own27", package: "Pkg27")])])

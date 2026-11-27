// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run19", dependencies: [.package(path: "../Pkg19")],
    targets: [.executableTarget(name: "Run19", dependencies: [.product(name: "Own19", package: "Pkg19")])])

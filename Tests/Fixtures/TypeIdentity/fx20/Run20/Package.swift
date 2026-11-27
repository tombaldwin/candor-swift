// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run20", dependencies: [.package(path: "../Pkg20")],
    targets: [.executableTarget(name: "Run20", dependencies: [.product(name: "Own20", package: "Pkg20")])])

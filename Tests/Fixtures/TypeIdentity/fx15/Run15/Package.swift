// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run15", dependencies: [.package(path: "../Pkg15")],
    targets: [.executableTarget(name: "Run15", dependencies: [.product(name: "Own15", package: "Pkg15")])])

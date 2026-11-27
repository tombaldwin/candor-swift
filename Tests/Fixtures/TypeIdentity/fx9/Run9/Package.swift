// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run9", dependencies: [.package(path: "../Pkg9")],
    targets: [.executableTarget(name: "Run9", dependencies: [.product(name: "Use9", package: "Pkg9")])])

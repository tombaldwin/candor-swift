// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run9r", dependencies: [.package(path: "../Pkg9r")],
    targets: [.executableTarget(name: "Run9r", dependencies: [.product(name: "Own9", package: "Pkg9r")])])

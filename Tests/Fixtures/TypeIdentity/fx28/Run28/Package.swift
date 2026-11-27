// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run28", dependencies: [.package(path: "../Pkg28")],
    targets: [.executableTarget(name: "Run28", dependencies: [.product(name: "Own28", package: "Pkg28")])])

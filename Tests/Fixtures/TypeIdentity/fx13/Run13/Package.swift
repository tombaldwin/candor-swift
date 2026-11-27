// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run13", dependencies: [.package(path: "../Pkg13")],
    targets: [.executableTarget(name: "Run13", dependencies: [.product(name: "Own13", package: "Pkg13")])])

// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run12", dependencies: [.package(path: "../Pkg12")],
    targets: [.executableTarget(name: "Run12", dependencies: [.product(name: "Own12", package: "Pkg12"), .product(name: "Feat12", package: "Pkg12")])])

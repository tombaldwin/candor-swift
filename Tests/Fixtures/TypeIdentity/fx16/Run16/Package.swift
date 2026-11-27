// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run16", dependencies: [.package(path: "../App16")],
    targets: [.executableTarget(name: "Run16", dependencies: [.product(name: "Feat16", package: "App16"), .product(name: "Ext16", package: "App16")])])

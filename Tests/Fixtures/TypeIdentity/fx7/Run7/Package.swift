// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run7", dependencies: [.package(path: "../App7")],
    targets: [.executableTarget(name: "Run7", dependencies: [.product(name: "Feature", package: "App7")])])

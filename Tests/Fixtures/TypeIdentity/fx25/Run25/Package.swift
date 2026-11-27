// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run25", dependencies: [.package(path: "../App25")],
    targets: [.executableTarget(name: "Run25", dependencies: [.product(name: "Feat25", package: "App25")])])

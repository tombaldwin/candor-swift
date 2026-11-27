// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Run10", dependencies: [.package(path: "../Pkg10")],
    targets: [.executableTarget(name: "Run10", dependencies: [.product(name: "Use10", package: "Pkg10")])])

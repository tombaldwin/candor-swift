// swift-tools-version:5.9
import PackageDescription
// a THIRD package whose module extends DepA's types (a different package from DepA, so a join keyed by DepA's package cannot reach it)
let package = Package(name: "ExtA", products: [.library(name: "DepAX", targets: ["DepAX"])],
    dependencies: [.package(path: "../DepA")],
    targets: [.target(name: "DepAX", dependencies: [.product(name: "DepA", package: "DepA")])])

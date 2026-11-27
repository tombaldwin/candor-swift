// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Guess", products: [.library(name: "Guess", targets: ["Guess"])],
    dependencies: [.package(path: "../Dep2")],
    targets: [.target(name: "Guess", dependencies: [.product(name: "Dep2", package: "Dep2")])])

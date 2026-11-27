// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
    dependencies: [.package(path: "../Guess")],
    targets: [.target(name: "App", dependencies: [.product(name: "Guess", package: "Guess")])])

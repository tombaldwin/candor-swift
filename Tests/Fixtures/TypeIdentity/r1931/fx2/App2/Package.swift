// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "App2", products: [.library(name: "Feature", targets: ["Feature"]), .library(name: "Core", targets: ["Core"])],
    dependencies: [.package(path: "../../fx/Guess")],
    targets: [.target(name: "Core"),
              .target(name: "Feature", dependencies: [.product(name: "Guess", package: "Guess")])])

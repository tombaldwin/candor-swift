// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "App7", products: [.library(name: "Feature", targets: ["Feature"])],
    targets: [.target(name: "Core"), .target(name: "Feature", dependencies: ["Core"])])

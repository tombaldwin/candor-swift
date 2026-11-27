// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Dep11", products: [.library(name: "Base11", targets: ["Base11"]), .library(name: "Ext11X", targets: ["Ext11X"])],
    targets: [.target(name: "Base11"), .target(name: "Ext11X", dependencies: ["Base11"])])

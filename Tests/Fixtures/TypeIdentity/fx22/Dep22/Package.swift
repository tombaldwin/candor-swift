// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Dep22", products: [.library(name: "Base22", targets: ["Base22"]), .library(name: "Ext22X", targets: ["Ext22X"])],
    targets: [.target(name: "Base22"), .target(name: "Ext22X", dependencies: ["Base22"])])

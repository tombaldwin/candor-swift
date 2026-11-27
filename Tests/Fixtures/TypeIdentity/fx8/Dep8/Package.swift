// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Dep8", products: [.library(name: "Base8", targets: ["Base8"]), .library(name: "Ext8X", targets: ["Ext8X"])],
    targets: [.target(name: "Base8"), .target(name: "Ext8X", dependencies: ["Base8"])])

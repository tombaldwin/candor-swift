// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "App8", products: [.library(name: "Feature8", targets: ["Feature8"])],
    dependencies: [.package(path: "../Dep8")],
    targets: [.target(name: "Feature8", dependencies: [.product(name: "Base8", package: "Dep8"), .product(name: "Ext8X", package: "Dep8")])])

// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Dep2", products: [.library(name: "Dep2", targets: ["Dep2"])], targets: [.target(name: "Dep2")])

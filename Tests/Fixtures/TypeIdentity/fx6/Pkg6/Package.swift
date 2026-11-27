// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Pkg6", products: [.library(name: "ToolA", targets: ["ToolA"]), .library(name: "ToolB", targets: ["ToolB"]), .library(name: "ToolC", targets: ["ToolC"])],
    targets: [.target(name: "Gen"), .target(name: "ToolA"), .target(name: "ToolB"), .target(name: "ToolC")])

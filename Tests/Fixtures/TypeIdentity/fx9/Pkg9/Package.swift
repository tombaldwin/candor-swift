// swift-tools-version:5.9
import PackageDescription
// S12 (a platform name a scan type shadows) beside S1 (the scan type is TOP-LEVEL in a sibling target the use file does not import).
let package = Package(name: "Pkg9",
    products: [.library(name: "Use9", targets: ["Use9"])],
    dependencies: [.package(path: "../Files")],
    targets: [.target(name: "Core9"), .target(name: "Gen9"),
              .target(name: "Use9", dependencies: [.product(name: "Files", package: "Files")])])

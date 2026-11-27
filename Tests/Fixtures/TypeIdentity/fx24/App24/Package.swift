// swift-tools-version:5.9
import PackageDescription
// lane B3 (SOUNDNESS R1981): use files whose imports are NOT a subset of the declaring file's.
let package = Package(name: "App24", products: [.library(name: "Feat24", targets: ["Feat24"])],
    dependencies: [.package(path: "../DepA"), .package(path: "../DepB"), .package(path: "../ExtA")],
    targets: [.target(name: "Core24", dependencies: [.product(name: "DepA", package: "DepA")]),
              .target(name: "Feat24", dependencies: [.product(name: "DepA", package: "DepA"), .product(name: "DepB", package: "DepB"),
                                                     .product(name: "DepAX", package: "ExtA"), "Core24"])])

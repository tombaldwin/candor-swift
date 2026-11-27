// swift-tools-version:5.9
import PackageDescription
// S7e variants of fx8. `Feature11`: only a.swift imports the modules, b.swift reaches the extension member through a FIELD, a
// FACTORY RETURN and a LOCAL declared in a.swift's types. `Feature11mi`: the target enables MemberImportVisibility (SE-0444), under
// which an extension member is visible only in a file that imports the extending module; every file here does.
let package = Package(name: "App11", products: [.library(name: "Feature11", targets: ["Feature11"]), .library(name: "Feature11mi", targets: ["Feature11mi"])],
    dependencies: [.package(path: "../Dep11")],
    targets: [.target(name: "Feature11", dependencies: [.product(name: "Base11", package: "Dep11"), .product(name: "Ext11X", package: "Dep11")]),
              .target(name: "Feature11mi", dependencies: [.product(name: "Base11", package: "Dep11"), .product(name: "Ext11X", package: "Dep11")],
                      swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")])])

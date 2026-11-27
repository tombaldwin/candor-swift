// swift-tools-version:5.9
import PackageDescription
// L3 attack cells (lane L3). Feature22's a.swift imports ONLY Base22 and declares the fields, the global, the factory; s.swift is a
// SIBLING importing Ext22X; b.swift imports nothing; c.swift imports Foundation and Ext22X (a module a.swift does not import).
let package = Package(name: "App22", products: [.library(name: "Feature22", targets: ["Feature22"]), .library(name: "Core22", targets: ["Core22"])],
    dependencies: [.package(path: "../Dep22")],
    targets: [.target(name: "Core22"),
              .target(name: "Feature22", dependencies: [.product(name: "Base22", package: "Dep22"), .product(name: "Ext22X", package: "Dep22")])])

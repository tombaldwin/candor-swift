// swift-tools-version:5.9
import PackageDescription
// L4 attack cells (lane L4, the supertype walk): a bare name reached as a MEMBER TYPE or MEMBER ALIAS of a supertype (or of the enclosing
// type) where the package ALSO declares the same simple name elsewhere, so the package-wide simple key (or a unique leaf) answers wrong.
// Core26 is imported by Feat26 (its top-level types are visible there); Dep26 is a dependency whose superclass nests types.
let package = Package(name: "App26", products: [.library(name: "Feat26", targets: ["Feat26"])],
    dependencies: [.package(path: "../Dep26")],
    targets: [.target(name: "Core26"),
              .target(name: "Feat26", dependencies: ["Core26", .product(name: "Dep26", package: "Dep26")])])

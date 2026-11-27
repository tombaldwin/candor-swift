// swift-tools-version:5.9
import PackageDescription
// LS REFUSAL cells. No target of this package declares a TOP-LEVEL `Data`, so the only scan types named `Data` are the NESTED ones
// Swift's own scope really does see from some cells (`Outer9.Data`, the superclass's `Base9.Data`).
let package = Package(name: "Pkg9r", products: [.library(name: "Own9", targets: ["Own9"])], targets: [.target(name: "Own9")])

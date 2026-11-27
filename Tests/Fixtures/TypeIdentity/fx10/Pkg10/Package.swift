// swift-tools-version:5.9
import PackageDescription
// L4 rows: a nested type reached through INHERITANCE (a superclass in another own module, in a dependency, generic), through a
// protocol-extension typealias, through an associatedtype, and a nested type declared in an extension of a foreign type.
let package = Package(name: "Pkg10", products: [.library(name: "Use10", targets: ["Use10"])],
    dependencies: [.package(path: "../Guess10")],
    targets: [.target(name: "Base10"),
              .target(name: "Use10", dependencies: ["Base10", .product(name: "Guess10", package: "Guess10")])])

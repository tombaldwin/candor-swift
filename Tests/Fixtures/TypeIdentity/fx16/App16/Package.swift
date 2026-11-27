// swift-tools-version:5.9
import PackageDescription
// Lane L2 (SOUNDNESS R1938, R1947, R1950): use-unit spellings with NO `Wiper`-style conformance on the dependency type, so the
// standalone and unreadable arms read the binding alone (no protocol hedge can stand in for it). Ext16 nests a type in an
// extension of a Feat16 type: Feat16's own files cannot see it.
let package = Package(name: "App16", products: [.library(name: "Feat16", targets: ["Feat16"]), .library(name: "Core16", targets: ["Core16"]),
                                                 .library(name: "Ext16", targets: ["Ext16"])],
    dependencies: [.package(path: "../Dep16")],
    targets: [.target(name: "Core16"),
              .target(name: "Feat16", dependencies: [.product(name: "Dep16", package: "Dep16")]),
              .target(name: "Ext16", dependencies: ["Feat16"])])

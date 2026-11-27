// swift-tools-version:5.9
import PackageDescription
// LS attack cells (R1938 lane LS): binder shapes, rebinds, refusals, and the platform-name F-B3r analogue.
let package = Package(name: "Pkg12",
    products: [.library(name: "Own12", targets: ["Own12"]), .library(name: "Feat12", targets: ["Feat12"])],
    targets: [.target(name: "Gen12"), .target(name: "Own12"), .target(name: "Core12"),
              .target(name: "Feat12", dependencies: ["Core12"])])

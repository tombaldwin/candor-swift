// swift-tools-version:5.9
import PackageDescription
// A minimal stand-in for JohnSundell's Files (the module name `Files` and the type name `File` are what the kappa registry keys on).
let package = Package(name: "Files", products: [.library(name: "Files", targets: ["Files"])], targets: [.target(name: "Files")])

// swift-tools-version:5.9
import PackageDescription
// A minimal stand-in for apple/swift-log: the same module name (`Logging`), the same public type name (`Logger`, which is also a
// kappa root: os.Logger / swift-log), and a handler PROTOCOL the logger dispatches through. The real package lives in the
// corpus pool, outside this repository.
let package = Package(name: "swift-log", products: [.library(name: "Logging", targets: ["Logging"])], targets: [.target(name: "Logging")])

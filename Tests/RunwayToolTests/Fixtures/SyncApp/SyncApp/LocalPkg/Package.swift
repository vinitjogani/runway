// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "LocalPkg", products: [.library(name: "LocalPkg", targets: ["LocalPkg"])], targets: [.target(name: "LocalPkg")])

// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SwiftTerm", platforms: [.macOS(.v14)], products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])], targets: [.target(name: "SwiftTerm", path: "Sources", exclude: ["Documentation.docc", "Mac/README.md"], resources: [.copy("Apple/Metal/Shaders.metal")])])

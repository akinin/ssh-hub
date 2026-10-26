// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SSHHub",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "Vendor/SwiftTerm")],
    targets: [
        .executableTarget(
            name: "SSHHub",
            dependencies: ["ConsoleSupport", .product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/SSHHub",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "SSHHubConsoleChecks",
            dependencies: ["ConsoleSupport", .product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "RuntimeTests"
        ),
        .target(
            name: "ConsoleSupport",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/ConsoleSupport"
        ),
    ]
)

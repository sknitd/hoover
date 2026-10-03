// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Hoover",
    platforms: [.macOS(.v13)],
    products: [.library(name: "HooverCore", targets: ["HooverCore"])],
    targets: [
        .target(name: "HooverCore"),
        .testTarget(name: "HooverCoreTests", dependencies: ["HooverCore"])
    ]
)

#if os(macOS)
package.products.append(.executable(name: "Hoover", targets: ["Hoover"]))
package.targets.append(.executableTarget(name: "Hoover", dependencies: ["HooverCore"], resources: [.copy("Resources")]))
package.targets.append(.testTarget(name: "HooverMacTests", dependencies: ["Hoover", "HooverCore"]))
#endif

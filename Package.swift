// swift-tools-version:5.9
import PackageDescription

var targets: [Target] = [
    .target(name: "AntigravityCore", path: "Sources/AntigravityCore",
            linkerSettings: [.linkedLibrary("util", .when(platforms: [.linux]))]),
    .executableTarget(name: "agcode", dependencies: ["AntigravityCore"], path: "Sources/agcode"),
    .testTarget(name: "AntigravityCoreTests", dependencies: ["AntigravityCore"], path: "Tests/AntigravityCoreTests"),
]
var products: [Product] = [
    .library(name: "AntigravityCore", targets: ["AntigravityCore"]),
    .executable(name: "agcode", targets: ["agcode"]),
]

#if os(macOS)
targets.append(.executableTarget(name: "AntigravityCodeApp", dependencies: ["AntigravityCore"], path: "Sources/AntigravityCodeApp"))
products.append(.executable(name: "AntigravityCodeApp", targets: ["AntigravityCodeApp"]))
#endif

let package = Package(
    name: "AntigravityCode",
    platforms: [.macOS(.v12)],
    products: products,
    targets: targets
)

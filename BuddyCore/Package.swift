// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BuddyCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "BuddyCore", targets: ["BuddyCore"])],
    targets: [
        .target(name: "BuddyCore", resources: [.copy("Draw/Resources/PatrickHand")]),
        .testTarget(name: "BuddyCoreTests", dependencies: ["BuddyCore"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)

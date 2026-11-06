// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BuddyVoice",
    platforms: [.macOS("26.0")],
    products: [.library(name: "BuddyVoice", targets: ["BuddyVoice"])],
    dependencies: [
        .package(path: "../BuddyCore"),
        // Only the text-to-speech half of FluidAudio, with NeMo text normalization so "$5" is read as "five dollars".
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.18.0",
            traits: ["TTS", "NemoTextProcessing"]
        )
    ],
    targets: [
        .target(name: "BuddyVoice", dependencies: [
            .product(name: "BuddyCore", package: "BuddyCore"),
            .product(name: "FluidAudio", package: "FluidAudio")
        ]),
        .executableTarget(name: "install-voice", dependencies: ["BuddyVoice"])
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.2
// What the Mac and the phone share: the records they meet in, how each is sealed, the pairing's
// key agreement and the commands. Foundation, CryptoKit and CloudKit only.
import PackageDescription

let package = Package(
    name: "Link",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "Link", targets: ["Link"])],
    targets: [
        .target(name: "Link"),
        .testTarget(name: "LinkTests", dependencies: ["Link"]),
    ]
)

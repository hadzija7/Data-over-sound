// swift-tools-version:5.9
import PackageDescription

// Platform-independent codec, framing, synthesis and tone detection used by the iOS app.
// The Xcode app target compiles these same source files directly; this package exists so the
// logic can be unit-tested with `swift test` on macOS or Linux without a device.
let package = Package(
    name: "DataOverSoundCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "DataOverSoundCore", targets: ["DataOverSoundCore"])
    ],
    targets: [
        .target(name: "DataOverSoundCore"),
        .testTarget(name: "DataOverSoundCoreTests", dependencies: ["DataOverSoundCore"])
    ]
)

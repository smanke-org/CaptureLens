// swift-tools-version: 6.2
import PackageDescription

// The shared logic lives in CaptureLensKit, a plain Swift package so `swift test` runs it
// without Xcode. The app is built by project.yml (XcodeGen), which links this package:
// CloudKit needs a provisioning profile, which only an Xcode build signs in.
let package = Package(
    name: "CaptureLensKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CaptureLensKit", targets: ["CaptureLensKit"]),
    ],
    targets: [
        .target(name: "CaptureLensKit"),
        .testTarget(name: "CaptureLensKitTests", dependencies: ["CaptureLensKit"]),
    ]
)

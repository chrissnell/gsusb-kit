// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GSUSBKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GSUSBKit", targets: ["GSUSBKit"]),
        // A product, not just a target, so a host application can test its own
        // adapter layer against a scripted device. See `ScriptedUsbTransport`.
        .library(name: "GSUSBKitTestSupport", targets: ["GSUSBKitTestSupport"]),
        // A product, not just a target, because `swift build --product
        // gsusbprobe` is the CI step that links `IOUSBHostTransport` against
        // the real frameworks — the one file no test can execute.
        .executable(name: "gsusbprobe", targets: ["gsusbprobe"]),
    ],
    targets: [
        // No dependencies, by design: a CAN adapter driver that needed a
        // protobuf runtime or a database to build would not be usable by
        // anything that did not already want those. The frameworks are linked
        // for `IOUSBHostTransport`, the one file here that touches hardware;
        // everything else is byte and integer arithmetic, which is what lets
        // the whole driver be tested with no adapter attached.
        .target(name: "GSUSBKit", linkerSettings: [
            .linkedFramework("IOUSBHost"),
            .linkedFramework("IOKit"),
        ]),
        .target(name: "GSUSBKitTestSupport", dependencies: ["GSUSBKit"]),
        // Reads the adapter and prints. The only thing that ever runs
        // `IOUSBHostTransport`.
        .executableTarget(name: "gsusbprobe", dependencies: ["GSUSBKit"]),
        .testTarget(name: "GSUSBKitTests", dependencies: [
            "GSUSBKit", "GSUSBKitTestSupport",
        ]),
    ],
    swiftLanguageModes: [.v6]
)

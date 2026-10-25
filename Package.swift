// swift-tools-version:5.9
// Apprentice: a Cakewalk-style MIDI sequencer for Apple platforms, built on libsseq.
//
// This package holds the platform-neutral Swift layer (SequencerKit, a Swift wrapper over the
// libsseq C API) and the CoreMIDI adapter (CoreMIDIKit). The macOS application lives in Apps/ and
// is generated with XcodeGen from project.yml; it depends on these two libraries.
import PackageDescription

let package = Package(
    name: "Apprentice",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SequencerKit", targets: ["SequencerKit"]),
        .library(name: "CoreMIDIKit", targets: ["CoreMIDIKit"]),
        .library(name: "SynthKit", targets: ["SynthKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/zaskar9/libsseq.git", from: "0.4.1"),
    ],
    targets: [
        .target(
            name: "SequencerKit",
            dependencies: [.product(name: "SSeq", package: "libsseq")]
        ),
        .target(
            name: "CoreMIDIKit",
            dependencies: ["SequencerKit"]
        ),
        .target(
            name: "SynthKit",
            dependencies: ["SequencerKit", "CoreMIDIKit"]
        ),
        .testTarget(
            name: "SequencerKitTests",
            dependencies: ["SequencerKit"]
        ),
    ]
)

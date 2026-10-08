// swift-tools-version: 6.0
import PackageDescription

// RawInputKit: camera RAW decoding for iOS and macOS, Apple's decoder first, then LibRaw.
// See Docs/ARCHITECTURE.md.
let package = Package(
    name: "RawInputKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RawInputKit", targets: ["RawInputKit"]),
        .executable(name: "rawprobe", targets: ["rawprobe"]),
    ],
    targets: [
        // LibRaw 0.22.2 from the submodule, under CDDL-1.0: its files stay unmodified or changes
        // are published. See THIRD-PARTY-NOTICES.md before editing Vendor/.
        .target(
            name: "CLibRaw",
            path: "Vendor/LibRaw",
            exclude: [
                // Stand-ins for stages left out of a build. Including both gives duplicate symbols.
                // When updating LibRaw, compare against the object list in its Makefile.devel.
                "src/postprocessing/postprocessing_ph.cpp",
                "src/preprocessing/preprocessing_ph.cpp",
                "src/write/write_ph.cpp",
                // Listed so SwiftPM does not warn about a file with no rule.
                "src/Makefile",
            ],
            sources: ["src"],
            publicHeadersPath: "libraw",
            cxxSettings: [
                .headerSearchPath("."),
                .define("USE_ZLIB"),      // deflate-compressed DNG
                .define("USE_X3FTOOLS"),  // Sigma Foveon (X3F)
                // Off, because each needs a further library: USE_JPEG (lossy DNG), USE_DNGSDK
                // (JPEG XL DNG), USE_GPRSDK (GoPro). Apple's decoder covers the first two.
            ],
            linkerSettings: [.linkedLibrary("z")]
        ),
        // The C boundary. The only target that includes LibRaw headers.
        .target(
            name: "RawShim",
            dependencies: ["CLibRaw"],
            cxxSettings: [.headerSearchPath("../../Vendor/LibRaw")]
        ),
        // The library. The only target that imports RawShim.
        .target(
            name: "RawInputKit",
            dependencies: ["RawShim"],
            // Declares the one required-reason API in the dependency tree: LibRaw's stat().
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        // Measuring tools for macOS: coverage probe, benchmark, side-by-side comparisons.
        .executableTarget(
            name: "rawprobe",
            dependencies: ["RawInputKit"]
        ),
        .testTarget(
            name: "RawInputKitTests",
            dependencies: ["RawInputKit"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)

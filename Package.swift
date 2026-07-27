// swift-tools-version: 6.0
import PackageDescription

// Module layout follows docs/ARCHITECTURE.md. Dependencies point strictly
// downward: DFCore <- DFECS <- DFSim <- executables. No module imports one
// above it. Targets are added as their milestone begins -- DFRaws, DFWorld,
// DFRender and DFUI arrive in M4, M7 and M1 respectively.
let package = Package(
    name: "dwarf-fortress-apple",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DFCore", targets: ["DFCore"]),
        .library(name: "DFECS", targets: ["DFECS"]),
        .library(name: "DFSim", targets: ["DFSim"]),
        .executable(name: "dfsim", targets: ["dfsimCLI"]),
        .executable(name: "dftest", targets: ["DFTests"]),
    ],
    targets: [
        .target(name: "DFCore", swiftSettings: .df),
        .target(name: "DFECS", dependencies: ["DFCore"], swiftSettings: .df),
        .target(name: "DFSim", dependencies: ["DFCore", "DFECS"], swiftSettings: .df),
        .executableTarget(
            name: "dfsimCLI",
            dependencies: ["DFCore", "DFECS", "DFSim"],
            // Not "Sources/dfsim": the filesystem is case-insensitive, so that
            // path collides with the DFSim library target.
            path: "Sources/DFSimCLI",
            swiftSettings: .df
        ),
        // Tests are an executable, not a `.testTarget`. Neither swift-testing
        // nor XCTest ships with the Command Line Tools, and verification must
        // not require a full Xcode install -- see Sources/DFTesting.
        .target(name: "DFTesting", swiftSettings: .df),
        .executableTarget(
            name: "DFTests",
            dependencies: ["DFTesting", "DFCore", "DFECS", "DFSim"],
            swiftSettings: .df
        ),
    ]
)

extension [SwiftSetting] {
    /// Shared settings. Swift 6 language mode is non-negotiable: the sim runs
    /// off the main actor and strict concurrency is what keeps it honest.
    static var df: [SwiftSetting] {
        [.swiftLanguageMode(.v6)]
    }
}

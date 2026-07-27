// swift-tools-version: 6.0
import PackageDescription

// Dependencies point strictly downward: DFCore <- DFECS <- DFSim <-
// executables. No module imports one above it. Targets are added as their
// milestone begins -- DFRaws, DFWorld and DFUI arrive in M4, M7 and M1
// respectively; DFRender arrived in M1.
//
// This comment used to cite docs/ARCHITECTURE.md, which has never existed in
// this repository. The dependency rule above is the whole of what that
// reference was carrying, so it is stated here rather than pointed at.
let package = Package(
    name: "dwarf-fortress-apple",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DFCore", targets: ["DFCore"]),
        .library(name: "DFECS", targets: ["DFECS"]),
        .library(name: "DFSim", targets: ["DFSim"]),
        .library(name: "DFRender", targets: ["DFRender"]),
        .library(name: "DFUI", targets: ["DFUI"]),
        .executable(name: "dfsim", targets: ["dfsimCLI"]),
        .executable(name: "dftest", targets: ["DFTests"]),
    ],
    targets: [
        .target(name: "DFCore", swiftSettings: .df),
        .target(name: "DFECS", dependencies: ["DFCore"], swiftSettings: .df),
        .target(name: "DFSim", dependencies: ["DFCore", "DFECS"], swiftSettings: .df),
        // DFRender depends on DFSim to read snapshots. Nothing below depends on
        // it, so the simulation stays buildable and testable with no graphics
        // stack present.
        .target(name: "DFRender", dependencies: ["DFSim"], swiftSettings: .df),
        // DFUI deliberately does NOT depend on DFECS. It cannot reach `World`,
        // so Constitution III ("sim state is mutated only by applying Command
        // values from a queue") is enforced by the module graph rather than by
        // discipline -- there is no import that would let a click handler write
        // a component even if someone tried.
        .target(name: "DFUI", dependencies: ["DFCore", "DFSim", "DFRender"], swiftSettings: .df),
        .executableTarget(
            name: "dfsimCLI",
            dependencies: ["DFCore", "DFECS", "DFSim", "DFRender"],
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
            dependencies: ["DFTesting", "DFCore", "DFECS", "DFSim", "DFRender", "DFUI"],
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

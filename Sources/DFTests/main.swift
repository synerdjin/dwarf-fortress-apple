import DFTesting
import Darwin

// Suites are registered explicitly rather than discovered. Swift has no runtime
// test discovery without a test framework, and an explicit list is honest about
// what runs -- a test file that nobody registered is a test file that silently
// never runs, which is worse than not having written it.
registerFixedTests()
registerRNGStreamTests()
registerStateHasherTests()
registerCoordTests()
registerJobSystemTests()
registerECSTests()
registerListStorageTests()
registerMapStoreTests()

// `dftest Fixed` runs only matching suites and tests.
let filter = CommandLine.arguments.dropFirst().first
exit(runRegisteredSuites(filter: filter))

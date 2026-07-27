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
registerRenderTests()

// `dftest Fixed` runs only matching suites and tests.
// `dftest --max-skips 0` fails the run if any test skipped; the merge gate uses
// it, because a skip that nobody counts is how "the GPU tests stopped running"
// looks exactly like a green build.
var filter: String?
var maxSkips: Int?
var remaining = Array(CommandLine.arguments.dropFirst())
while let argument = remaining.first {
  remaining.removeFirst()
  if argument == "--max-skips" {
    guard let value = remaining.first.flatMap(Int.init) else {
      print("dftest: --max-skips needs a number")
      exit(2)
    }
    remaining.removeFirst()
    maxSkips = value
  } else if argument.hasPrefix("--") {
    print("dftest: unknown option \(argument)")
    exit(2)
  } else if filter == nil {
    filter = argument
  } else {
    print("dftest: unexpected argument \(argument)")
    exit(2)
  }
}

exit(runRegisteredSuites(filter: filter, maxSkips: maxSkips))

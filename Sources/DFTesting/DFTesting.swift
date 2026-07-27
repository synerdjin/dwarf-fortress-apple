/// A minimal test harness.
///
/// Why not swift-testing or XCTest: neither ships with the Command Line Tools,
/// so `swift test` cannot run without a full Xcode install. Verification is the
/// backbone of this project and must never depend on a GUI toolchain being
/// present -- an agent that cannot run the tests cannot do the work. This
/// harness is about a hundred lines, has no dependencies, and runs as a plain
/// executable anywhere the compiler exists.
///
/// It is deliberately serial. Tests that need to prove something about
/// parallelism spawn their own threads and assert on the results; the harness
/// itself introduces no concurrency, so a failure is always reproducible.
///
/// The registry is single-threaded by construction: registration happens on the
/// main thread before the run, and the run is serial.
nonisolated(unsafe) private var registry = Registry()

private struct Registry {
  var suites: [(name: String, body: () -> Void)] = []
  var currentSuite: String = ""
  var currentTest: String = ""
  var failures: [Failure] = []
  var testsRun = 0
  var testsFailed = 0
  var failuresInCurrentTest = 0
  var filter: String?
  /// Result lines for the suite currently running, so suites with no matching
  /// tests can be omitted from output entirely.
  var suiteOutput: [String] = []
}

private struct Failure {
  let suite: String
  let test: String
  let message: String
  let file: String
  let line: UInt
}

/// Declares a suite. Bodies run when `runRegisteredSuites()` is called, not at
/// registration time, so ordering is explicit rather than dependent on
/// initialization order.
public func suite(_ name: String, _ body: @escaping () -> Void) {
  registry.suites.append((name: name, body: body))
}

/// Declares a test inside a suite body.
public func test(_ name: String, _ body: () -> Void) {
  if let filter = registry.filter,
    !registry.currentSuite.lowercased().contains(filter.lowercased()),
    !name.lowercased().contains(filter.lowercased())
  {
    return
  }

  registry.currentTest = name
  registry.failuresInCurrentTest = 0
  registry.testsRun += 1

  body()

  if registry.failuresInCurrentTest > 0 {
    registry.testsFailed += 1
    registry.suiteOutput.append("  ✗ \(name)")
  } else {
    registry.suiteOutput.append("  ✓ \(name)")
  }
  registry.currentTest = ""
}

/// Records a failure if `condition` is false.
public func expect(
  _ condition: Bool,
  _ message: @autoclosure () -> String = "",
  file: String = #fileID,
  line: UInt = #line
) {
  guard !condition else { return }
  record(message().isEmpty ? "expectation failed" : message(), file: file, line: line)
}

/// Preferred over `expect(a == b)`: on failure it reports both values, which is
/// the difference between a usable failure and a bisection session.
public func expectEqual<T: Equatable>(
  _ actual: T,
  _ expected: T,
  _ message: @autoclosure () -> String = "",
  file: String = #fileID,
  line: UInt = #line
) {
  guard actual != expected else { return }
  let context = message().isEmpty ? "" : " -- \(message())"
  record("expected \(expected), got \(actual)\(context)", file: file, line: line)
}

public func expectNotEqual<T: Equatable>(
  _ actual: T,
  _ unexpected: T,
  _ message: @autoclosure () -> String = "",
  file: String = #fileID,
  line: UInt = #line
) {
  guard actual == unexpected else { return }
  let context = message().isEmpty ? "" : " -- \(message())"
  record("expected value to differ from \(unexpected)\(context)", file: file, line: line)
}

private func record(_ message: String, file: String, line: UInt) {
  registry.failures.append(
    Failure(
      suite: registry.currentSuite,
      test: registry.currentTest,
      message: message,
      file: file,
      line: line
    )
  )
  registry.failuresInCurrentTest += 1
}

/// Runs every registered suite. Returns a process exit code: 0 on success.
public func runRegisteredSuites(filter: String? = nil) -> Int32 {
  registry.filter = filter

  for entry in registry.suites {
    registry.currentSuite = entry.name
    // Always run the body: `test` decides per-test whether the filter
    // matches, so a filter can select individual tests inside a suite whose
    // own name does not match. Results are buffered so that a suite with no
    // matching tests prints nothing at all.
    registry.suiteOutput = []
    entry.body()
    if !registry.suiteOutput.isEmpty {
      print(entry.name)
      for line in registry.suiteOutput { print(line) }
    }
  }

  print("")
  if registry.failures.isEmpty {
    print("PASS: \(registry.testsRun) tests, 0 failures")
    return 0
  }

  print("FAILURES:")
  for failure in registry.failures {
    print("  \(failure.file):\(failure.line)")
    print("    \(failure.suite) / \(failure.test)")
    print("    \(failure.message)")
  }
  print("")
  print(
    "FAIL: \(registry.testsRun) tests, \(registry.testsFailed) failed, \(registry.failures.count) failed expectations"
  )
  return 1
}

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
  var skips: [Skip] = []
  var testsRun = 0
  var testsFailed = 0
  var failuresInCurrentTest = 0
  var skipReasonForCurrentTest: String?
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

private struct Skip {
  let suite: String
  let test: String
  let reason: String
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
  registry.skipReasonForCurrentTest = nil
  registry.testsRun += 1

  body()

  if registry.failuresInCurrentTest > 0 {
    registry.testsFailed += 1
    registry.suiteOutput.append("  ✗ \(name)")
  } else if let reason = registry.skipReasonForCurrentTest {
    registry.testsRun -= 1
    registry.skips.append(Skip(suite: registry.currentSuite, test: name, reason: reason))
    registry.suiteOutput.append("  ⊘ \(name) -- SKIPPED: \(reason)")
  } else {
    registry.suiteOutput.append("  ✓ \(name)")
  }
  registry.currentTest = ""
  registry.skipReasonForCurrentTest = nil
}

/// Declares that the current test could not run, and why.
///
/// This exists because the alternative that grew here first --
/// `expect(true, "skipped")` -- is indistinguishable from a passing test in
/// every place a human or an agent looks: the ✓, the count, the exit code.
/// Invariant V ("tests per module") is worth nothing if a test that never ran
/// reports the same thing as one that did.
///
/// A skip is not a failure, but it is not a pass either. Skips are counted,
/// listed by name and reason at the end of the run, and `--max-skips N` turns
/// more than `N` of them into exit code 1 -- which is how `Scripts/ci.sh` keeps
/// "the GPU tests silently stopped running" from looking like a green build.
///
/// Skip only on an environmental precondition the test cannot create, such as
/// a machine with no Metal device. Never on an error the code under test
/// produced: that is the bug the test was written to find.
public func skip(_ reason: String) {
  guard !registry.currentTest.isEmpty else { return }
  registry.skipReasonForCurrentTest = reason
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
///
/// - Parameter maxSkips: How many skipped tests this run tolerates. `nil`
///   tolerates any number; `0` -- what the merge gate uses on a machine that
///   has a GPU -- makes a skip a failure.
public func runRegisteredSuites(filter: String? = nil, maxSkips: Int? = nil) -> Int32 {
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

  if !registry.skips.isEmpty {
    print("SKIPPED:")
    for skip in registry.skips {
      print("  \(skip.suite) / \(skip.test)")
      print("    \(skip.reason)")
    }
    print("")
  }

  let skipCount = registry.skips.count
  let skipSuffix = skipCount == 0 ? "" : ", \(skipCount) skipped"

  if !registry.failures.isEmpty {
    print("FAILURES:")
    for failure in registry.failures {
      print("  \(failure.file):\(failure.line)")
      print("    \(failure.suite) / \(failure.test)")
      print("    \(failure.message)")
    }
    print("")
    print(
      "FAIL: \(registry.testsRun) tests, \(registry.testsFailed) failed, \(registry.failures.count) failed expectations\(skipSuffix)"
    )
    return 1
  }

  // A run that skipped more than it was allowed to did not verify what it was
  // asked to verify, whatever the ✓ column says.
  if let maxSkips, skipCount > maxSkips {
    print(
      "FAIL: \(registry.testsRun) tests, 0 failures, but \(skipCount) skipped and --max-skips is \(maxSkips)"
    )
    return 1
  }

  print("PASS: \(registry.testsRun) tests, 0 failures\(skipSuffix)")
  return 0
}

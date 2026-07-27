import Dispatch

/// Deterministic parallel execution.
///
/// The hard requirement is that running a tick phase across four workers must
/// produce byte-identical state to running it across one. That is not achieved
/// by locking -- locks make results *safe*, not *reproducible*, because the
/// order in which contending threads win is still arbitrary. It is achieved by
/// structure:
///
/// 1. Work is split into **contiguous, ordered** index ranges *before* dispatch.
///    Partition `i` always covers the same indices; no worker ever claims work
///    dynamically.
/// 2. Workers either write to **disjoint** output slots, or accumulate into a
///    **per-partition scratch buffer**.
/// 3. Scratch buffers are merged **in partition order**, on the calling thread,
///    after the barrier.
///
/// Together these give a stronger property than "no data races": because the
/// partitions are contiguous and merged in order, the merged sequence is the
/// same one a single-threaded pass would produce. The result therefore does not
/// depend on the partition count *at all* -- which is exactly what
/// `dfsim determinism-check --threads 1,2,4` asserts.
///
/// The failure mode this design rules out is the one that would otherwise end
/// this project: a fortress that desynchronises from its own replay after an
/// hour because two haulers were assigned in a different order on a busy frame.
public final class JobSystem: @unchecked Sendable {
  /// What kind of work is being scheduled, which determines both the worker
  /// count and the quality of service.
  public enum Workload: Sendable {
    /// Latency-sensitive tick-loop work. Runs on performance cores.
    case simulation
    /// Throughput work tolerant of being descheduled: worldgen, history,
    /// save compression.
    case background

    var defaultPartitionCount: Int {
      switch self {
      case .simulation: CPUTopology.simulationWorkerCount
      case .background: CPUTopology.backgroundWorkerCount
      }
    }

    var qos: DispatchQoS.QoSClass {
      switch self {
      case .simulation: .userInteractive
      case .background: .utility
      }
    }
  }

  /// Forces every dispatch to run inline on the calling thread.
  ///
  /// Used by `determinism-check` to produce the reference result, and by
  /// debugging sessions where a real stack trace beats a parallel one.
  public var forceSerial: Bool

  /// Overrides the partition count for every dispatch that does not name one.
  ///
  /// This is what `dfsim determinism-check --threads 1,2,4` actually varies.
  /// Without it the check would be vacuous: thread *count* is not something a
  /// caller controls under `concurrentPerform`, but the decomposition is, and
  /// the decomposition is what a correct system must be invariant to.
  public var partitionCountOverride: Int?

  public init(forceSerial: Bool = false, partitionCountOverride: Int? = nil) {
    self.forceSerial = forceSerial
    self.partitionCountOverride = partitionCountOverride
  }

  /// Partitions to use when a call site does not specify.
  func resolvedPartitionCount(_ requested: Int?, _ workload: Workload) -> Int {
    requested ?? partitionCountOverride ?? workload.defaultPartitionCount
  }

  // MARK: - Partitioning

  /// Splits `range` into at most `count` contiguous pieces, largest first by
  /// remainder distribution.
  ///
  /// Contiguity and order are load-bearing, not incidental: they are what let
  /// per-partition results be concatenated into the single-threaded answer.
  public static func partition(_ range: Range<Int>, into count: Int) -> [Range<Int>] {
    let total = range.count
    guard total > 0 else { return [] }
    let pieces = max(1, min(count, total))
    let baseSize = total / pieces
    let remainder = total % pieces

    var result: [Range<Int>] = []
    result.reserveCapacity(pieces)
    var start = range.lowerBound
    for index in 0..<pieces {
      // The first `remainder` partitions take one extra element, so sizes
      // differ by at most one and no partition is empty.
      let size = baseSize + (index < remainder ? 1 : 0)
      result.append(start..<(start + size))
      start += size
    }
    return result
  }

  // MARK: - Disjoint-write parallel for

  /// Runs `body` once per partition. Use when workers write only to slots
  /// indexed by the elements they were given, so no merging is needed.
  ///
  /// `body` receives the partition's index range and its partition number.
  public func parallelFor(
    _ range: Range<Int>,
    workload: Workload = .simulation,
    partitionCount: Int? = nil,
    _ body: @Sendable (Range<Int>, Int) -> Void
  ) {
    let count = resolvedPartitionCount(partitionCount, workload)
    let partitions = JobSystem.partition(range, into: count)
    guard !partitions.isEmpty else { return }

    if forceSerial || partitions.count == 1 {
      for (index, piece) in partitions.enumerated() {
        body(piece, index)
      }
      return
    }

    DispatchQueue.concurrentPerform(iterations: partitions.count) { index in
      body(partitions[index], index)
    }
  }

  // MARK: - Accumulate-and-merge parallel for

  /// Runs `body` once per partition with private scratch storage, then merges
  /// the scratch values **in partition order** on the calling thread.
  ///
  /// This is the pattern for any system that produces effects rather than
  /// writing in place -- spawning entities, queueing follow-up commands,
  /// appending to an announcement log. Because partitions are contiguous and
  /// merged in order, the resulting sequence is identical to a serial run
  /// regardless of how many partitions were used.
  ///
  /// - Parameters:
  ///   - makeScratch: Produces a fresh, empty accumulator per partition.
  ///   - body: Fills its partition's accumulator. Must not touch shared state.
  ///   - merge: Consumes accumulators in partition order.
  public func parallelReduce<Scratch>(
    _ range: Range<Int>,
    workload: Workload = .simulation,
    partitionCount: Int? = nil,
    makeScratch: () -> Scratch,
    body: @Sendable (Range<Int>, Int, inout Scratch) -> Void,
    merge: (inout Scratch, Int) -> Void
  ) {
    let count = resolvedPartitionCount(partitionCount, workload)
    let partitions = JobSystem.partition(range, into: count)
    guard !partitions.isEmpty else { return }

    let pieceCount = partitions.count
    // `nonisolated(unsafe)` because the compiler cannot see what makes this
    // safe: iteration `i` touches only slot `i`, so the concurrent writes go
    // to disjoint memory and never overlap. This is the one place that
    // reasoning is asserted by hand rather than proved by the type system.
    nonisolated(unsafe) let scratch = UnsafeMutableBufferPointer<Scratch>.allocate(
      capacity: pieceCount
    )
    defer {
      scratch.baseAddress!.deinitialize(count: pieceCount)
      scratch.deallocate()
    }
    for index in 0..<pieceCount {
      scratch.baseAddress!.advanced(by: index).initialize(to: makeScratch())
    }

    // Each iteration touches exactly one scratch slot, so the concurrent
    // writes are to disjoint memory.
    if forceSerial || pieceCount == 1 {
      for index in 0..<pieceCount {
        body(partitions[index], index, &scratch.baseAddress!.advanced(by: index).pointee)
      }
    } else {
      DispatchQueue.concurrentPerform(iterations: pieceCount) { index in
        body(partitions[index], index, &scratch.baseAddress!.advanced(by: index).pointee)
      }
    }

    // The barrier has passed; merging is serial and in partition order.
    for index in 0..<pieceCount {
      merge(&scratch.baseAddress!.advanced(by: index).pointee, index)
    }
  }

  /// Convenience over `parallelReduce` for the common case of gathering
  /// arrays of results into one flat array in index order.
  public func parallelCollect<Element>(
    _ range: Range<Int>,
    workload: Workload = .simulation,
    partitionCount: Int? = nil,
    body: @Sendable (Range<Int>, inout [Element]) -> Void
  ) -> [Element] {
    var output: [Element] = []
    parallelReduce(
      range,
      workload: workload,
      partitionCount: partitionCount,
      makeScratch: { [Element]() },
      body: { piece, _, scratch in body(piece, &scratch) },
      merge: { scratch, _ in output.append(contentsOf: scratch) }
    )
    return output
  }
}

import DFCore
import DFTesting

func registerJobSystemTests() {
  suite("SPEC-M0-CORE: Deterministic job system") {
    test("Partitions are contiguous, ordered, complete, and balanced") {
      // Contiguity and order are not cosmetic -- they are the reason
      // per-partition results can be concatenated into the serial answer.
      for total in [0, 1, 2, 7, 100, 1000] {
        for pieces in [1, 2, 3, 4, 8, 16] {
          let partitions = JobSystem.partition(0..<total, into: pieces)

          if total == 0 {
            expect(partitions.isEmpty, "empty range should yield no partitions")
            continue
          }

          var covered = 0
          var expectedStart = 0
          for piece in partitions {
            expect(piece.lowerBound == expectedStart, "partitions must be contiguous")
            expect(!piece.isEmpty, "partitions must be non-empty")
            expectedStart = piece.upperBound
            covered += piece.count
          }
          expectEqual(covered, total, "partitions must cover the range exactly")
          expectEqual(expectedStart, total, "partitions must end at the range end")

          // Sizes differ by at most one, so no worker is left holding a
          // disproportionate share and stalling the barrier.
          if let smallest = partitions.map(\.count).min(),
            let largest = partitions.map(\.count).max()
          {
            expect(largest - smallest <= 1, "partition sizes must differ by at most 1")
          }
        }
      }
    }

    test("Partition count never exceeds the element count") {
      // Asking for 16 partitions over 3 elements must not produce empty
      // partitions, which would allocate scratch buffers that never get filled.
      let partitions = JobSystem.partition(0..<3, into: 16)
      expectEqual(partitions.count, 3)
      expect(partitions.allSatisfy { !$0.isEmpty })
    }

    test("Partitions respect a non-zero lower bound") {
      let partitions = JobSystem.partition(100..<110, into: 3)
      expectEqual(partitions.first?.lowerBound, 100)
      expectEqual(partitions.last?.upperBound, 110)
    }

    test("Disjoint writes produce identical output at every partition count") {
      let count = 5000
      var reference: [Int] = []

      for pieces in [1, 2, 3, 4, 8, 16, 64] {
        let jobs = JobSystem()
        var output = [Int](repeating: 0, count: count)
        output.withUnsafeMutableBufferPointer { buffer in
          nonisolated(unsafe) let slots = buffer
          jobs.parallelFor(0..<count, partitionCount: pieces) { piece, _ in
            for index in piece {
              slots[index] = index * index
            }
          }
        }
        if pieces == 1 {
          reference = output
        } else {
          expect(output == reference, "partition count \(pieces) diverged")
        }
      }
      expectEqual(reference[10], 100)
    }

    test("Reduce merges in partition order, independent of partition count") {
      // The central claim of the design. Appending from parallel workers is the
      // classic source of run-to-run divergence; here the merged sequence must
      // equal the serial sequence no matter how the work was split.
      let count = 2000
      let expected = Array(0..<count)

      for pieces in [1, 2, 3, 4, 5, 8, 16, 64, 128] {
        let jobs = JobSystem()
        let collected = jobs.parallelCollect(0..<count, partitionCount: pieces) {
          (piece, scratch: inout [Int]) in
          for index in piece { scratch.append(index) }
        }
        expect(collected == expected, "partition count \(pieces) produced a different order")
      }
    }

    test("Forced serial execution matches parallel execution") {
      // `forceSerial` is what determinism-check compares against, so it must
      // agree with the parallel path exactly rather than approximately.
      let count = 3000

      let serialJobs = JobSystem(forceSerial: true)
      let serial = serialJobs.parallelCollect(0..<count, partitionCount: 8) {
        (piece, scratch: inout [Int]) in
        for index in piece { scratch.append(index * 3) }
      }

      let parallelJobs = JobSystem()
      let parallel = parallelJobs.parallelCollect(0..<count, partitionCount: 8) {
        (piece, scratch: inout [Int]) in
        for index in piece { scratch.append(index * 3) }
      }

      expect(serial == parallel)
      expectEqual(serial.count, count)
    }

    test("Repeated runs of the same parallel work are bit-identical") {
      // Ten runs, because a race that shows up one time in three would pass a
      // single-run test and then fail in CI a week later.
      let count = 4000
      var digests: Set<UInt64> = []

      for _ in 0..<10 {
        let jobs = JobSystem()
        let collected = jobs.parallelCollect(0..<count, partitionCount: 8) {
          (piece, scratch: inout [Int]) in
          for index in piece where index % 3 == 0 { scratch.append(index) }
        }
        var hasher = StateHasher()
        for value in collected { hasher.combine(value) }
        digests.insert(hasher.value)
      }

      expectEqual(digests.count, 1, "parallel work produced different results across runs")
    }

    test("Per-partition RNG sub-streams stay deterministic under parallelism") {
      // The combination that matters in practice: parallel work that also draws
      // random numbers. Each partition seeds from its own sub-stream, so the
      // draws depend on the element index rather than on which thread ran it.
      let count = 1000
      var reference: [UInt32] = []

      for pieces in [1, 2, 4, 16] {
        let jobs = JobSystem()
        let drawn = jobs.parallelCollect(0..<count, partitionCount: pieces) {
          (piece, scratch: inout [UInt32]) in
          for index in piece {
            var rng = RNGStream(seed: 999, .worldgenStrata, sub: UInt64(index))
            scratch.append(rng.next())
          }
        }
        if pieces == 1 {
          reference = drawn
        } else {
          expect(drawn == reference, "partition count \(pieces) drew different numbers")
        }
      }
      expectEqual(reference.count, count)
    }

    test("Empty ranges are a no-op, not a crash") {
      let jobs = JobSystem()
      var invocations = 0
      withUnsafeMutablePointer(to: &invocations) { pointer in
        nonisolated(unsafe) let counter = pointer
        jobs.parallelFor(0..<0) { _, _ in counter.pointee += 1 }
      }
      expectEqual(invocations, 0)

      let collected = jobs.parallelCollect(0..<0) { (_, scratch: inout [Int]) in
        scratch.append(1)
      }
      expect(collected.isEmpty)
    }

    test("Single-element ranges work") {
      let jobs = JobSystem()
      let collected = jobs.parallelCollect(0..<1, partitionCount: 8) {
        (piece, scratch: inout [Int]) in
        for index in piece { scratch.append(index) }
      }
      expectEqual(collected, [0])
    }

    test("Topology reports a sane asymmetric core layout") {
      expect(CPUTopology.totalCoreCount >= 1)
      expect(CPUTopology.performanceCoreCount >= 1)
      expect(CPUTopology.efficiencyCoreCount >= 0)
      expect(CPUTopology.simulationWorkerCount >= 1)
      expect(
        CPUTopology.performanceCoreCount + CPUTopology.efficiencyCoreCount
          <= CPUTopology.totalCoreCount
      )
    }
  }
}

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

    test("parallelStencil produces identical output at every partition count") {
      // A 1D three-point stencil (each slot reads its left and right
      // neighbour from the previous tick): the shape M3's thermal diffusion
      // will actually use. `source` and `destination` are different backing
      // arrays, so this is the safe, double-buffered pattern -- contrast with
      // the in-place negative test below.
      let count = 200
      var reference: [Int] = []

      for pieces in [1, 2, 3, 7, 16] {
        let source = Array(0..<count)
        var destination = [Int](repeating: 0, count: count)
        source.withUnsafeBufferPointer { src in
          destination.withUnsafeMutableBufferPointer { dst in
            JobSystem().parallelStencil(
              0..<count, partitionCount: pieces, read: src, write: dst
            ) { index, source in
              let left = index > 0 ? source[index - 1] : 0
              let right = index < source.count - 1 ? source[index + 1] : 0
              return left + source[index] + right
            }
          }
        }
        if pieces == 1 {
          reference = destination
        } else {
          expect(destination == reference, "partition count \(pieces) diverged")
        }
      }
      // Sanity: slot 10 sees 9 + 10 + 11.
      expectEqual(reference[10], 30)
    }

    test("DoubleBuffered's front and back are distinct, and swap() exchanges them") {
      let buffer = DoubleBuffered<Int>(count: 4, repeating: 0)
      expectEqual(Array(buffer.front), [0, 0, 0, 0])

      buffer.back[0] = 42
      expectEqual(buffer.front[0], 0, "writing to back must not be visible through front before swap()")

      buffer.swap()
      expectEqual(buffer.front[0], 42, "swap() must make the just-written buffer the new front")

      // The buffer just vacated by front is now back, and holds whatever it
      // held after the *previous* swap -- the initial zero-fill, in this case
      // -- not a stale copy of the old front.
      expectEqual(buffer.back[0], 0)
      buffer.back[1] = 7
      buffer.swap()
      expectEqual(buffer.front[0], 0, "the buffer holding tick 0's data must resurface, not tick 1's")
      expectEqual(buffer.front[1], 7)
    }

    test("ActiveSet built via parallelCollect is sorted for free, at every partition count") {
      // The claim `ActiveSet` depends on: parallelCollect's contiguous,
      // partition-ordered merge produces a strictly increasing sequence with
      // no separate sort step, because each partition already appends in
      // increasing order and partitions are merged low-to-high.
      let count = 500
      for pieces in [1, 2, 3, 5, 16] {
        let jobs = JobSystem()
        let collected = jobs.parallelCollect(0..<count, partitionCount: pieces) {
          (piece, scratch: inout [Int]) in
          for index in piece where index % 7 == 0 { scratch.append(index) }
        }
        let set = ActiveSet(sortedUnique: collected)
        expectEqual(set.sortedIndices, collected)
        expectEqual(set.count, collected.count)
        expect(set.contains(0))
        expect(set.contains(497))
        expect(!set.contains(1))
      }
    }

    test("ActiveSet.insert keeps sorted order and de-duplicates") {
      var set = ActiveSet()
      for value in [5, 1, 3, 1, 9, 3] { set.insert(value) }
      expectEqual(set.sortedIndices, [1, 3, 5, 9])
      expect(set.contains(3))
      expect(!set.contains(4))
    }

    test("ActiveSet.merging combines two sorted sets without concatenate-then-sort") {
      let a = ActiveSet(sortedUnique: [1, 3, 5, 7])
      let b = ActiveSet(sortedUnique: [2, 3, 6])
      let merged = a.merging(b)
      expectEqual(merged.sortedIndices, [1, 2, 3, 5, 6, 7], "duplicates must collapse, order must stay sorted")
    }

    test("An in-place stencil's result depends on visitation order (why double-buffering exists)") {
      // The exact hazard the constitution names: "its result depends on
      // whether a neighbour was visited before or after the tile reading it,
      // which is exactly the partition boundary." Demonstrated by processing
      // order rather than real thread scheduling, so the divergence itself is
      // reproducible rather than a race whose outcome depends on hardware
      // timing -- the point is that the result is order-dependent at all, and
      // that property doesn't need a real race to show.
      let count = 32
      func runInPlace(partitionOrder: [Int]) -> [Int] {
        var buffer = [Int](repeating: 0, count: count)
        let partitions = JobSystem.partition(0..<count, into: 4)
        for partitionIndex in partitionOrder {
          for index in partitions[partitionIndex] where index > 0 {
            // In place: reads whatever `buffer[index - 1]` currently holds,
            // which is last tick's value or a value already overwritten this
            // tick, depending on which partition ran first.
            buffer[index] = buffer[index - 1] + 1
          }
        }
        return buffer
      }

      let forward = runInPlace(partitionOrder: [0, 1, 2, 3])
      let reversed = runInPlace(partitionOrder: [3, 2, 1, 0])
      expect(forward != reversed, "an in-place stencil should be order-dependent, but was not")
      expectEqual(
        forward, Array(0..<count),
        "processed low-to-high, the in-place version happens to look correct -- which is exactly the trap")
    }

    test("Seeding an RNG sub-stream by partition, not element, diverges across partition counts") {
      // The wrong version of the pattern the earlier positive test proves
      // safe: seeding once per *partition* rather than once per *element*
      // means the same element draws from a different sub-stream, and gets a
      // different number, purely because of how work happened to be split.
      let count = 1000
      var results: [[UInt32]] = []

      for pieces in [1, 2, 4, 16] {
        let jobs = JobSystem()
        let drawn = jobs.parallelCollect(0..<count, partitionCount: pieces) {
          (piece, scratch: inout [UInt32]) in
          // Deliberate mistake: one stream per partition instead of one per
          // element.
          var rng = RNGStream(seed: 999, .testing, sub: UInt64(piece.lowerBound))
          for _ in piece { scratch.append(rng.next()) }
        }
        results.append(drawn)
      }

      let allIdentical = results.dropFirst().allSatisfy { $0 == results[0] }
      expect(!allIdentical, "partition-seeded RNG should diverge across partition counts, but did not")
    }

    test("Partitions writing into shared, colliding scratch diverge with processing order") {
      // The hazard `parallelReduce`'s per-partition-scratch-then-merge design
      // exists to avoid: two partitions writing the *same* slot in one shared
      // buffer instead of each writing its own scratch that gets merged in
      // order afterward. Whichever partition writes a colliding slot last
      // wins -- under real concurrent dispatch that is scheduler-decided;
      // simulated here by explicit processing order, same reasoning as the
      // in-place stencil test above.
      let partitions = JobSystem.partition(0..<16, into: 4)
      func run(order: [Int]) -> [Int] {
        var scratch = [Int](repeating: -1, count: 4)
        for partitionIndex in order {
          for index in partitions[partitionIndex] {
            scratch[index % scratch.count] = index  // colliding write, last one wins
          }
        }
        return scratch
      }

      let forward = run(order: [0, 1, 2, 3])
      let reversed = run(order: [3, 2, 1, 0])
      expect(
        forward != reversed,
        "colliding shared scratch should diverge with processing order, but did not")
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

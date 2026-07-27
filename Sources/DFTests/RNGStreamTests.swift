import DFCore
import DFTesting

func registerRNGStreamTests() {
  suite("SPEC-M0-CORE: RNG streams") {
    test("The generator is pinned: a seed produces one specific sequence forever") {
      // Hard-coded because the whole point is that this never changes. Every
      // replay fixture in the project is downstream of these exact numbers;
      // if a refactor perturbs them, the failure must surface here rather
      // than as a hundred mysterious hash mismatches elsewhere.
      var rng = RNGStream(seed: 0xDEAD_BEEF, .testing)
      let drawn = (0..<6).map { _ in rng.next() }
      expect(
        drawn == [
          1_487_557_411, 1_570_080_700, 1_300_336_784, 320_685_847, 2_261_563_296, 48_832_616,
        ])
    }

    test("Same seed and domain replay identically") {
      var a = RNGStream(seed: 12345, .combat)
      var b = RNGStream(seed: 12345, .combat)
      for _ in 0..<1000 {
        expect(a.next() == b.next())
      }
      expect(a == b)
    }

    test("Domains are independent at the same seed") {
      // This is invariant 2's actual payoff: a new die roll in combat must
      // not shift what worldgen or moods see.
      var combat = RNGStream(seed: 7, .combat)
      var moods = RNGStream(seed: 7, .moods)
      var terrain = RNGStream(seed: 7, .worldgenTerrain)

      let combatDraws = (0..<200).map { _ in combat.next() }
      let moodDraws = (0..<200).map { _ in moods.next() }
      let terrainDraws = (0..<200).map { _ in terrain.next() }

      expect(combatDraws != moodDraws)
      expect(combatDraws != terrainDraws)
      expect(moodDraws != terrainDraws)

      // Independence is stronger than inequality: the sequences must not be
      // shifts of one another, which a naive seed+n scheme would produce.
      expect(!combatDraws.dropFirst(1).elementsEqual(moodDraws.dropLast(1)))
      expect(!combatDraws.dropFirst(10).elementsEqual(moodDraws.dropLast(10)))
    }

    test("Sub-streams within a domain are independent") {
      var chunkA = RNGStream(seed: 99, .worldgenStrata, sub: 0)
      var chunkB = RNGStream(seed: 99, .worldgenStrata, sub: 1)
      var chunkC = RNGStream(seed: 99, .worldgenStrata, sub: 2)

      let a = (0..<100).map { _ in chunkA.next() }
      let b = (0..<100).map { _ in chunkB.next() }
      let c = (0..<100).map { _ in chunkC.next() }

      expect(a != b)
      expect(b != c)
      expect(!a.dropFirst(1).elementsEqual(b.dropLast(1)))
    }

    test("Sub-streams make chunk generation order-independent") {
      // Generating chunks forward and backward must produce identical
      // terrain. Without per-chunk streams this fails, and worldgen could
      // never be parallelised.
      func generate(order: [UInt64]) -> [UInt64: UInt32] {
        var result: [UInt64: UInt32] = [:]
        for chunk in order {
          var rng = RNGStream(seed: 4242, .worldgenStrata, sub: chunk)
          result[chunk] = rng.next()
        }
        return result
      }

      let forward = generate(order: Array(0..<50))
      let backward = generate(order: Array((0..<50).reversed()))
      expect(forward == backward)
    }

    test("Bounded draws stay in range and are unbiased") {
      var rng = RNGStream(seed: 1, .testing)
      var buckets = [Int](repeating: 0, count: 6)
      let trials = 120_000
      for _ in 0..<trials {
        let value = rng.next(upperBound: 6)
        expect(value < 6)
        buckets[Int(value)] += 1
      }
      // Deterministic input, so a tight bound is safe -- this will never
      // flake, and a loose bound would not catch modulo bias.
      let expected = trials / 6
      for count in buckets {
        expect(abs(count - expected) < expected / 40)
      }
    }

    test("Integer ranges cover their bounds") {
      var rng = RNGStream(seed: 2, .testing)
      var seenLow = false
      var seenHigh = false
      for _ in 0..<2000 {
        let value = rng.int(in: 10..<15)
        expect(value >= 10 && value < 15)
        if value == 10 { seenLow = true }
        if value == 14 { seenHigh = true }
      }
      expect(seenLow && seenHigh)

      for _ in 0..<200 {
        let closed = rng.int(in: 3...3)
        expect(closed == 3)
      }
    }

    test("Rational chances hit their expected rate and handle the edges") {
      var rng = RNGStream(seed: 3, .testing)
      expect(rng.chance(0, in: 100) == false)
      expect(rng.chance(100, in: 100) == true)
      expect(rng.chance(-5, in: 100) == false)
      expect(rng.chance(200, in: 100) == true)

      var hits = 0
      let trials = 100_000
      for _ in 0..<trials where rng.chance(1, in: 4) { hits += 1 }
      expect(abs(hits - trials / 4) < trials / 100)
    }

    test("unitFixed stays in [0, 1)") {
      var rng = RNGStream(seed: 5, .testing)
      for _ in 0..<10000 {
        let value = rng.unitFixed()
        expect(value >= Fixed.zero)
        expect(value < Fixed.one)
      }
    }

    test("Shuffle is a deterministic permutation") {
      var a = Array(0..<64)
      var b = Array(0..<64)
      var rngA = RNGStream(seed: 8, .testing)
      var rngB = RNGStream(seed: 8, .testing)
      rngA.shuffle(&a)
      rngB.shuffle(&b)

      expect(a == b)
      expect(a.sorted() == Array(0..<64))
      expect(a != Array(0..<64))
    }

    test("advance(by:) matches drawing n times") {
      // Jump-ahead is what lets a system reconstruct generator state for tick
      // N without replaying N ticks of draws, so it must agree exactly with
      // the slow path.
      for jump in [0, 1, 2, 7, 64, 1000] as [UInt64] {
        var slow = RNGStream(seed: 77, .testing)
        var fast = RNGStream(seed: 77, .testing)
        for _ in 0..<jump { _ = slow.next() }
        fast.advance(by: jump)
        expect(slow == fast, "jump of \(jump) diverged")
        expect(slow.next() == fast.next())
      }
    }

    test("RNGStream is a trivial 16-byte value that can live in sim state") {
      expect(MemoryLayout<RNGStream>.size == 16)
      expect(MemoryLayout<RNGStream>.stride == 16)
    }

    test("Domain raw values are frozen") {
      // Renumbering a domain silently invalidates every saved world, so the
      // wire values are asserted rather than left to declaration order.
      expect(RNGDomain.worldgenTerrain.rawValue == 0)
      expect(RNGDomain.combat.rawValue == 8)
      expect(RNGDomain.reactions.rawValue == 15)
      expect(RNGDomain.testing.rawValue == 1000)
    }
  }
}

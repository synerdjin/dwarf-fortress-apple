import DFCore
import DFTesting

func registerStateHasherTests() {
  suite("SPEC-M0-CORE: State hashing") {
    test("Digests are pinned and not process-seeded") {
      // The single most important assertion in the project. Swift's built-in
      // Hasher is seeded per process and would produce different values on
      // every run; if this hasher ever acquired that property, every replay
      // fixture would fail nondeterministically and nobody would know why.
      // Hard-coded goldens make that failure immediate and obvious.
      var zero = StateHasher()
      zero.combine(UInt64(0))
      expect(zero.hex == "25fc6dd36ce04b20")

      var coord = StateHasher()
      coord.combine(Coord3(3, -7, 12))
      expect(coord.hex == "b60d08752b5731a2")

      var buffer = StateHasher()
      let bytes: [UInt8] = Array(0..<20)
      bytes.withUnsafeBufferPointer { buffer.combine(buffer: $0) }
      expect(buffer.hex == "ecffcc1d00b164ab")
    }

    test("Identical input yields identical digests within a run") {
      func digest() -> UInt64 {
        var hasher = StateHasher()
        hasher.combine(Coord3(1, 2, 3))
        hasher.combine(Fixed(1, over: 3))
        hasher.combine(Int32(-42))
        hasher.combine(true)
        return hasher.value
      }
      expect(digest() == digest())
    }

    test("A single changed bit changes the digest") {
      func digest(_ value: Int32) -> UInt64 {
        var hasher = StateHasher()
        hasher.combine(value)
        return hasher.value
      }
      expect(digest(0) != digest(1))
      expect(digest(1) != digest(-1))
      expect(digest(1 << 30) != digest((1 << 30) + 1))
    }

    test("Order matters") {
      var forward = StateHasher()
      forward.combine(Int32(1))
      forward.combine(Int32(2))

      var backward = StateHasher()
      backward.combine(Int32(2))
      backward.combine(Int32(1))

      // Entity iteration order is part of sim state. A commutative hash would
      // silently accept a reordering that changes job assignment outcomes.
      expect(forward.value != backward.value)
    }

    test("Trailing zeros are distinguishable from absent bytes") {
      func digest(_ bytes: [UInt8]) -> UInt64 {
        var hasher = StateHasher()
        bytes.withUnsafeBufferPointer { hasher.combine(buffer: $0) }
        return hasher.value
      }
      // Without the length prefix in the tail word, these three collide, and
      // a truncated stockpile array would hash the same as a full one.
      expect(digest([0]) != digest([0, 0]))
      expect(digest([0, 0]) != digest([0, 0, 0]))
      expect(digest([1, 2, 3]) != digest([1, 2, 3, 0]))
    }

    test("Buffer hashing spans the word boundary correctly") {
      // Exercises the 8-byte bulk path and every possible tail length, since
      // an off-by-one there would only show up for particular array sizes.
      var digests: Set<UInt64> = []
      for count in 0...24 {
        let values = [UInt8](repeating: 7, count: count)
        var hasher = StateHasher()
        values.withUnsafeBufferPointer { hasher.combine(buffer: $0) }
        digests.insert(hasher.value)
      }
      expect(digests.count == 25)
    }

    test("Typed buffers hash by their bytes") {
      let values: [Int32] = [1, 2, 3, 4, 5]
      var fromBuffer = StateHasher()
      values.withUnsafeBufferPointer { fromBuffer.combine(buffer: $0) }

      var changed = StateHasher()
      let other: [Int32] = [1, 2, 3, 4, 6]
      other.withUnsafeBufferPointer { changed.combine(buffer: $0) }

      expect(fromBuffer.value != changed.value)
    }

    test("Empty buffers hash to a defined value") {
      var hasher = StateHasher()
      let empty: [Int32] = []
      empty.withUnsafeBufferPointer { hasher.combine(buffer: $0) }

      var zero = StateHasher()
      zero.combine(UInt64(0))
      expect(hasher.value == zero.value)
    }

    test("RNG stream position contributes to the digest") {
      // Two runs that reached the same visible state while consuming
      // different numbers of draws have already diverged; they just have not
      // shown it yet. Hashing stream position catches it at the tick it
      // happened rather than whenever the next roll finally differs.
      let early = RNGStream(seed: 1, .combat)
      var late = RNGStream(seed: 1, .combat)
      _ = late.next()

      var a = StateHasher()
      a.combine(early)
      var b = StateHasher()
      b.combine(late)
      expect(a.value != b.value)
    }

    test("Hex is zero-padded to 16 digits") {
      var hasher = StateHasher()
      hasher.combine(UInt64(0))
      expect(hasher.hex.count == 16)
      expect(hasher.hex.allSatisfy { $0.isHexDigit })
    }

    test("Padding detection flags types unsafe for buffer hashing") {
      struct Packed: BitwiseCopyable {
        var a: Int32
        var b: Int32
      }
      struct Padded: BitwiseCopyable {
        var a: Int64
        var b: Int8
      }

      // Interior padding feeds uninitialized bytes into combine(buffer:),
      // which is a genuine source of run-to-run hash instability. Component
      // types get checked against this in their own suites.
      expect(StateHasher.hasNoPadding(Packed.self, fieldByteCount: 8))
      expect(!StateHasher.hasNoPadding(Padded.self, fieldByteCount: 9))
    }
  }
}

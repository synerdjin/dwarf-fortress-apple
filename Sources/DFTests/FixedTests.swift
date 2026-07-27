import DFCore
import DFTesting

func registerFixedTests() {
  suite("SPEC-M0-CORE: Fixed-point arithmetic") {
    test("Q16.16 scaling is exact for whole numbers") {
      expect(Fixed.one.raw == 65536)
      expect(Fixed(1).raw == 65536)
      expect(Fixed(-3).raw == -196_608)
      expect(Fixed.half.raw == 32768)
      expect(Fixed(0) == Fixed.zero)
    }

    test("Rational construction truncates toward zero at the last bit") {
      // 65536/3 is not an integer, so a third is representable only to within
      // one epsilon. Asserting the exact raw value pins that we truncate
      // rather than round -- three thirds must not silently become 1.0000.
      expect(Fixed(1, over: 3).raw == 21845)
      expect(Fixed(1, over: 3) * 3 == Fixed(raw: 65535))
      expect(Fixed(1, over: 3) * 3 < Fixed.one)
      expect(Fixed(1, over: 2) == Fixed.half)
      expect(Fixed(3, over: 4).raw == 49152)
    }

    test("Addition and subtraction are exact") {
      expect(Fixed(3) + Fixed(4) == Fixed(7))
      expect(Fixed(3) - Fixed(4) == Fixed(-1))
      expect(-Fixed(5) == Fixed(-5))
      expect(Fixed.half + Fixed.half == Fixed.one)

      var accumulator = Fixed.zero
      for _ in 0..<1000 { accumulator += Fixed(1, over: 8) }
      // 1/8 is a power of two and therefore exactly representable, so a
      // thousand additions must land precisely on 125 with no drift. This is
      // the property floating point cannot give us and the reason invariant 1
      // exists.
      expect(accumulator == Fixed(125))
    }

    test("Multiplication of exactly-representable values is exact") {
      expect(Fixed(1, over: 2) * Fixed(1, over: 2) == Fixed(1, over: 4))
      expect(Fixed(3) * Fixed(4) == Fixed(12))
      expect(Fixed(-3) * Fixed(4) == Fixed(-12))
      expect(Fixed(1, over: 4) * 8 == Fixed(2))
      expect(8 * Fixed(1, over: 4) == Fixed(2))

      // The Int64 intermediate is load-bearing: 200 * 200 exceeds Int32 once
      // both operands are scaled by 65536.
      expect(Fixed(200) * Fixed(100) == Fixed(20000))
    }

    test("Division inverts multiplication") {
      expect(Fixed(12) / Fixed(4) == Fixed(3))
      expect(Fixed(1) / Fixed(2) == Fixed.half)
      expect(Fixed(-12) / Fixed(4) == Fixed(-3))
      expect(Fixed(12) / 4 == Fixed(3))
    }

    test("floor rounds toward negative infinity, not toward zero") {
      // Truncation toward zero would make the origin tile two units wide,
      // which quietly breaks every coordinate conversion that follows.
      expect(Fixed(1, over: 2).floor == 0)
      expect(Fixed(-1, over: 2).floor == -1)
      expect(Fixed(-3, over: 2).floor == -2)
      expect(Fixed(3).floor == 3)
      expect(Fixed(-3).floor == -3)
    }

    test("rounded takes halves upward") {
      expect(Fixed(1, over: 2).rounded == 1)
      expect(Fixed(1, over: 4).rounded == 0)
      expect(Fixed(3, over: 4).rounded == 1)
      expect(Fixed(-1, over: 2).rounded == 0)
      expect(Fixed(-3, over: 4).rounded == -1)
    }

    test("fraction is always non-negative") {
      expect(Fixed(3, over: 2).fraction == Fixed.half)
      expect(Fixed(-1, over: 2).fraction == Fixed.half)
      expect(Fixed(3).fraction == Fixed.zero)
    }

    test("Ordering and clamping") {
      expect(Fixed(1) < Fixed(2))
      expect(Fixed(-2) < Fixed(-1))
      expect(Fixed(5).clamped(to: Fixed(0)...Fixed(3)) == Fixed(3))
      expect(Fixed(-5).clamped(to: Fixed(0)...Fixed(3)) == Fixed.zero)
      expect(Fixed(2).clamped(to: Fixed(0)...Fixed(3)) == Fixed(2))
      expect([Fixed(3), Fixed(-1), Fixed(2)].sorted() == [Fixed(-1), Fixed(2), Fixed(3)])
    }

    test("Description is readable for debugging") {
      expect(Fixed(1, over: 2).description == "0.5000")
      expect(Fixed(-1, over: 2).description == "-0.5000")
      expect(Fixed(3).description == "3.0000")
      // Not "0.0100": a hundredth is not representable in Q16.16 (raw 655 is
      // 0.00999...), and description truncates rather than rounding so that
      // it shows the value actually stored. Percentage-like quantities should
      // be held as integer basis points, not as Fixed fractions.
      expect(Fixed(1, over: 100).description == "0.0099")
      expect(Fixed(1, over: 100).raw == 655)
    }

    test("Fixed is a trivial 4-byte value") {
      // Components hold these by the hundred thousand; if this ever grows,
      // something has crept into the type that does not belong in sim state.
      expect(MemoryLayout<Fixed>.size == 4)
      expect(MemoryLayout<Fixed>.stride == 4)
    }
  }
}

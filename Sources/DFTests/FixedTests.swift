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

    test("Every operator truncates toward zero") {
      // 1/3 is not representable, so each of these has bits to discard. The
      // point is the *direction*: toward zero on both sides of the origin, so
      // no operator is the odd one out. `*` used an arithmetic shift here,
      // which floors, and was the odd one out.
      expect(Fixed(1, over: 3).raw == 21845)
      expect(Fixed(-1, over: 3).raw == -21845)

      let third = Fixed(1, over: 3)
      expect((third * third).raw == 7281)  // floor would give 7281 too...
      // ...so use a product whose exact value is negative and inexact, where
      // floor and truncation actually disagree.
      expect((-third * third).raw == -7281)
      expect((third * -third).raw == -7281)

      expect((Fixed(1) / Fixed(3)).raw == 21845)
      expect((Fixed(-1) / Fixed(3)).raw == -21845)
      expect((Fixed(1) / -3).raw == -21845)
    }

    test("Negation is exact through multiply and divide") {
      // The identity a diffusion kernel needs in order to conserve: flux
      // computed from (a - b) must be the exact negative of flux computed from
      // (b - a). Under floor rounding these differ by one epsilon whenever the
      // product is inexact, and the pair leaks a fraction of a unit per tick
      // forever.
      let rate = Fixed(1, over: 3)
      var mismatches = 0
      for a in stride(from: -2000, through: 2000, by: 37) {
        for b in stride(from: -300, through: 300, by: 53) {
          let difference = Fixed(raw: Int32(a)) - Fixed(raw: Int32(b))
          let reverse = Fixed(raw: Int32(b)) - Fixed(raw: Int32(a))
          if difference * rate != -(reverse * rate) { mismatches += 1 }
          if difference / rate != -(reverse / rate) { mismatches += 1 }
          if difference / 7 != -(reverse / 7) { mismatches += 1 }
        }
      }
      expectEqual(mismatches, 0, "negation is not exact through the operators")
    }

    test("rounded traps rather than wrapping past Int32.max") {
      // Not directly testable without crashing the harness -- this pins the
      // boundary that is still safe, and the `+` in `rounded` (previously `&+`)
      // is what makes the next step a trap instead of a sign flip.
      // Fixed.max.raw + 32768 would wrap to a large negative under `&+`.
      expect(Fixed(raw: Int32.max - (1 << 15)).rounded == 32767)
      expect(Fixed(raw: Int32.min + (1 << 15)).rounded == -32767)
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

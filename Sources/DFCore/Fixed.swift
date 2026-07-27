/// Q16.16 signed fixed-point.
///
/// This is the only fractional numeric type permitted in simulation state
/// (invariant 1). Floating point is barred from the sim because its results
/// depend on instruction selection and evaluation order, which would make
/// bit-exact replay -- the project's entire regression strategy -- impossible.
///
/// Range is roughly ±32768 with a resolution of 1/65536. Quantities that need
/// more range (item counts, temperatures, tick stamps) are plain integers with
/// a documented unit, not `Fixed`.
///
/// Products and quotients are computed in `Int64` and trap on overflow rather
/// than wrapping. A silently wrapped flow rate is a fortress that desynchronises
/// from its own replay an hour later; a trap is a stack trace.
public struct Fixed: Hashable, Sendable, BitwiseCopyable {
  /// The underlying Q16.16 value. Public for serialization and hashing only --
  /// arithmetic should go through the operators.
  public var raw: Int32

  public static let fractionalBits: Int32 = 16
  @usableFromInline static let scale: Int64 = 1 << 16

  @inlinable
  public init(raw: Int32) {
    self.raw = raw
  }

  /// Exact conversion from a whole number. Traps if it does not fit.
  @inlinable
  public init(_ value: Int) {
    let scaled = Int64(value) << Fixed.fractionalBits
    precondition(
      scaled >= Int64(Int32.min) && scaled <= Int64(Int32.max),
      "Fixed overflow: \(value) is outside ±32768"
    )
    self.raw = Int32(scaled)
  }

  /// Exact rational construction, e.g. `Fixed(1, over: 3)`. This is how
  /// fractional constants enter the sim -- never by way of a float literal.
  @inlinable
  public init(_ numerator: Int, over denominator: Int) {
    precondition(denominator != 0, "Fixed division by zero")
    let scaled = (Int64(numerator) << Fixed.fractionalBits) / Int64(denominator)
    precondition(
      scaled >= Int64(Int32.min) && scaled <= Int64(Int32.max),
      "Fixed overflow: \(numerator)/\(denominator) is outside ±32768"
    )
    self.raw = Int32(scaled)
  }

  public static let zero = Fixed(raw: 0)
  public static let one = Fixed(raw: 1 << Fixed.fractionalBits)
  public static let half = Fixed(raw: 1 << (Fixed.fractionalBits - 1))
  public static let min = Fixed(raw: Int32.min)
  public static let max = Fixed(raw: Int32.max)

  /// Smallest representable step. Useful for epsilon comparisons in tests.
  public static let epsilon = Fixed(raw: 1)

  /// Largest integer not greater than the value. Floors toward negative
  /// infinity, so `floor(-0.5) == -1` -- consistent with tile coordinate math
  /// where truncation toward zero would make the origin two units wide.
  @inlinable
  public var floor: Int32 {
    raw >> Fixed.fractionalBits
  }

  /// Nearest integer, halves rounding toward positive infinity.
  @inlinable
  public var rounded: Int32 {
    (raw &+ (1 << (Fixed.fractionalBits - 1))) >> Fixed.fractionalBits
  }

  /// The fractional part, always in `[0, 1)` even for negative values.
  @inlinable
  public var fraction: Fixed {
    Fixed(raw: raw & 0xFFFF)
  }

  @inlinable
  public var magnitude: Fixed {
    Fixed(raw: raw < 0 ? -raw : raw)
  }
}

// MARK: - Arithmetic

extension Fixed: AdditiveArithmetic {
  @inlinable
  public static func + (lhs: Fixed, rhs: Fixed) -> Fixed {
    Fixed(raw: lhs.raw + rhs.raw)
  }

  @inlinable
  public static func - (lhs: Fixed, rhs: Fixed) -> Fixed {
    Fixed(raw: lhs.raw - rhs.raw)
  }

  @inlinable
  public static prefix func - (value: Fixed) -> Fixed {
    Fixed(raw: -value.raw)
  }
}

extension Fixed {
  /// Widened multiply then shift. The `Int64` intermediate is what keeps
  /// products of mid-range values exact instead of overflowing at ±181.
  @inlinable
  public static func * (lhs: Fixed, rhs: Fixed) -> Fixed {
    let product = (Int64(lhs.raw) * Int64(rhs.raw)) >> Fixed.fractionalBits
    precondition(
      product >= Int64(Int32.min) && product <= Int64(Int32.max),
      "Fixed multiply overflow"
    )
    return Fixed(raw: Int32(product))
  }

  @inlinable
  public static func / (lhs: Fixed, rhs: Fixed) -> Fixed {
    precondition(rhs.raw != 0, "Fixed division by zero")
    let quotient = (Int64(lhs.raw) << Fixed.fractionalBits) / Int64(rhs.raw)
    precondition(
      quotient >= Int64(Int32.min) && quotient <= Int64(Int32.max),
      "Fixed divide overflow"
    )
    return Fixed(raw: Int32(quotient))
  }

  /// Scaling by a whole number, which is more common in sim code than
  /// `Fixed * Fixed` and avoids the shift entirely.
  @inlinable
  public static func * (lhs: Fixed, rhs: Int) -> Fixed {
    let product = Int64(lhs.raw) * Int64(rhs)
    precondition(
      product >= Int64(Int32.min) && product <= Int64(Int32.max),
      "Fixed multiply overflow"
    )
    return Fixed(raw: Int32(product))
  }

  @inlinable
  public static func * (lhs: Int, rhs: Fixed) -> Fixed { rhs * lhs }

  @inlinable
  public static func / (lhs: Fixed, rhs: Int) -> Fixed {
    precondition(rhs != 0, "Fixed division by zero")
    return Fixed(raw: Int32(Int64(lhs.raw) / Int64(rhs)))
  }

  @inlinable
  public static func += (lhs: inout Fixed, rhs: Fixed) { lhs = lhs + rhs }

  @inlinable
  public static func -= (lhs: inout Fixed, rhs: Fixed) { lhs = lhs - rhs }

  @inlinable
  public static func *= (lhs: inout Fixed, rhs: Fixed) { lhs = lhs * rhs }

  @inlinable
  public static func /= (lhs: inout Fixed, rhs: Fixed) { lhs = lhs / rhs }

  @inlinable
  public func clamped(to range: ClosedRange<Fixed>) -> Fixed {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}

extension Fixed: Comparable {
  @inlinable
  public static func < (lhs: Fixed, rhs: Fixed) -> Bool { lhs.raw < rhs.raw }
}

extension Fixed: ExpressibleByIntegerLiteral {
  @inlinable
  public init(integerLiteral value: Int) {
    self.init(value)
  }
}

// MARK: - Debugging

extension Fixed: CustomStringConvertible {
  /// Renders with four decimal places. This is a debugging affordance only --
  /// the sim never parses it back, and no sim decision may depend on it.
  public var description: String {
    let negative = raw < 0
    let absolute = negative ? -Int64(raw) : Int64(raw)
    let whole = absolute >> Fixed.fractionalBits
    let fractional = (absolute & 0xFFFF) * 10000 / Fixed.scale
    var digits = "\(fractional)"
    while digits.count < 4 { digits = "0" + digits }
    return "\(negative ? "-" : "")\(whole).\(digits)"
  }
}

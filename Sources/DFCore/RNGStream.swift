/// The subsystem a random draw belongs to.
///
/// Each domain gets its own independent stream from the same world seed. This
/// is the point of the whole design: adding a die roll to combat must not shift
/// the numbers worldgen or strange moods observe. With a single shared
/// generator, every change to any subsystem is a change to all of them, and
/// every replay fixture in the project breaks at once.
///
/// Raw values are frozen. Renumbering a domain invalidates every saved world,
/// so append new cases at the end and never reorder.
public enum RNGDomain: UInt64, Sendable, CaseIterable {
  case worldgenTerrain = 0
  case worldgenClimate = 1
  case worldgenStrata = 2
  case worldgenCivs = 3
  case worldgenHistory = 4
  case creatureGeneration = 5
  case personality = 6
  case moods = 7
  case combat = 8
  case wounds = 9
  case jobSelection = 10
  case pathTieBreak = 11
  case weather = 12
  case wildlife = 13
  case trade = 14
  case reactions = 15
  /// For tests and synthetic fixtures only. Never draw from this in sim code.
  case testing = 1000
}

/// A deterministic, seekable pseudo-random generator: PCG-XSH-RR 64/32.
///
/// PCG is chosen over xoshiro or SplitMix specifically for its *stream*
/// parameter -- the increment selects one of 2^63 distinct sequences from the
/// same seed, which is exactly the per-domain independence invariant 2 calls
/// for, at no cost in state size or speed.
///
/// The type is a `BitwiseCopyable` value: streams live inside sim state, get
/// saved and restored verbatim, and a load resumes the exact sequence a save
/// interrupted.
public struct RNGStream: Sendable, BitwiseCopyable, Equatable {
  @usableFromInline var state: UInt64
  /// Always odd; the low bit is forced during construction.
  @usableFromInline var increment: UInt64

  @usableFromInline static let multiplier: UInt64 = 6_364_136_223_846_793_005

  /// The canonical constructor: a world seed plus a domain.
  @inlinable
  public init(seed: UInt64, _ domain: RNGDomain) {
    self.init(seed: seed, streamID: domain.rawValue)
  }

  /// A sub-stream within a domain, for per-entity or per-chunk independence.
  ///
  /// Worldgen uses this to make chunk generation order-independent: chunk
  /// (x, y) draws from its own stream, so generating a world in a different
  /// order -- or in parallel -- yields identical terrain.
  @inlinable
  public init(seed: UInt64, _ domain: RNGDomain, sub: UInt64) {
    // Mix the sub-id into the stream selector rather than the seed, so
    // sibling sub-streams stay decorrelated instead of merely offset.
    self.init(seed: seed, streamID: domain.rawValue &* 0x9E37_79B9_7F4A_7C15 &+ sub)
  }

  @inlinable
  init(seed: UInt64, streamID: UInt64) {
    self.increment = (streamID << 1) | 1
    self.state = 0
    _ = next()
    self.state = self.state &+ seed
    _ = next()
  }

  /// Raw 32 bits. The rotation is what breaks up the LCG's weak low bits.
  @inlinable
  public mutating func next() -> UInt32 {
    let old = state
    state = old &* RNGStream.multiplier &+ increment
    let xorshifted = UInt32(truncatingIfNeeded: ((old >> 18) ^ old) >> 27)
    let rotation = UInt32(truncatingIfNeeded: old >> 59)
    return (xorshifted >> rotation) | (xorshifted << ((~rotation &+ 1) & 31))
  }

  @inlinable
  public mutating func next64() -> UInt64 {
    let high = UInt64(next())
    let low = UInt64(next())
    return (high << 32) | low
  }

  /// Uniform in `0..<bound`, with rejection sampling to remove modulo bias.
  ///
  /// The bias matters more here than in most software: a 0.4% skew on a
  /// wound-location roll is invisible in testing and shows up as "why does
  /// everyone lose their left foot" after a thousand fortress-hours.
  @inlinable
  public mutating func next(upperBound bound: UInt32) -> UInt32 {
    precondition(bound > 0, "RNGStream upper bound must be positive")
    let threshold = (0 &- bound) % bound
    while true {
      let candidate = next()
      if candidate >= threshold {
        return candidate % bound
      }
    }
  }

  /// Uniform in a half-open integer range.
  @inlinable
  public mutating func int(in range: Range<Int>) -> Int {
    precondition(!range.isEmpty, "RNGStream range must be non-empty")
    let span = UInt32(range.count)
    return range.lowerBound + Int(next(upperBound: span))
  }

  /// Uniform in a closed integer range.
  @inlinable
  public mutating func int(in range: ClosedRange<Int>) -> Int {
    int(in: range.lowerBound..<(range.upperBound + 1))
  }

  /// A `numerator`-in-`denominator` chance. Expressed as a rational rather
  /// than a probability because invariant 1 bars the float that would
  /// otherwise be the natural spelling.
  @inlinable
  public mutating func chance(_ numerator: Int, in denominator: Int) -> Bool {
    precondition(denominator > 0, "RNGStream chance denominator must be positive")
    if numerator <= 0 { return false }
    if numerator >= denominator { return true }
    return Int(next(upperBound: UInt32(denominator))) < numerator
  }

  @inlinable
  public mutating func bool() -> Bool {
    next() & 1 == 1
  }

  /// Uniform `Fixed` in `[0, 1)`.
  @inlinable
  public mutating func unitFixed() -> Fixed {
    Fixed(raw: Int32(next() >> 16))
  }

  /// Uniform `Fixed` in a closed range.
  @inlinable
  public mutating func fixed(in range: ClosedRange<Fixed>) -> Fixed {
    let span = Int64(range.upperBound.raw) - Int64(range.lowerBound.raw)
    guard span > 0 else { return range.lowerBound }
    let offset = Int64(next(upperBound: UInt32(clamping: span + 1)))
    return Fixed(raw: Int32(Int64(range.lowerBound.raw) + offset))
  }

  /// Uniformly picks an element. Returns `nil` for an empty collection rather
  /// than trapping, since "no valid job site" is a normal sim outcome.
  @inlinable
  public mutating func pick<C: RandomAccessCollection>(_ collection: C) -> C.Element? {
    guard !collection.isEmpty else { return nil }
    let offset = Int(next(upperBound: UInt32(collection.count)))
    return collection[collection.index(collection.startIndex, offsetBy: offset)]
  }

  /// Fisher-Yates, drawing from this stream so the permutation is replayable.
  @inlinable
  public mutating func shuffle<T>(_ array: inout [T]) {
    guard array.count > 1 else { return }
    for i in stride(from: array.count - 1, to: 0, by: -1) {
      let j = Int(next(upperBound: UInt32(i + 1)))
      if i != j { array.swapAt(i, j) }
    }
  }

  /// Advances the stream by `n` draws in O(log n) rather than O(n).
  ///
  /// This is PCG's jump-ahead, and it is what lets a system reconstruct the
  /// exact generator state for tick N without replaying N ticks of draws.
  @inlinable
  public mutating func advance(by n: UInt64) {
    var accumulatedMultiplier: UInt64 = 1
    var accumulatedIncrement: UInt64 = 0
    var currentMultiplier = RNGStream.multiplier
    var currentIncrement = increment
    var delta = n

    while delta > 0 {
      if delta & 1 == 1 {
        accumulatedMultiplier = accumulatedMultiplier &* currentMultiplier
        accumulatedIncrement = accumulatedIncrement &* currentMultiplier &+ currentIncrement
      }
      currentIncrement = (currentMultiplier &+ 1) &* currentIncrement
      currentMultiplier = currentMultiplier &* currentMultiplier
      delta >>= 1
    }

    state = accumulatedMultiplier &* state &+ accumulatedIncrement
  }
}

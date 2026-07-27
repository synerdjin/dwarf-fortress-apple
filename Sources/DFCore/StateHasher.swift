/// A deterministic hash over simulation state.
///
/// This is the instrument the entire verification strategy rests on: after each
/// tick the sim folds its state into one of these, and `dfsim replay
/// --assert-hashes` compares the resulting sequence against a golden fixture. A
/// change that alters behaviour anywhere shows up as a hash divergence at the
/// exact tick it first mattered, which is the difference between "something is
/// wrong somewhere" and a bisectable bug.
///
/// It is emphatically *not* Swift's `Hasher`, which is seeded per-process and
/// therefore produces different values on every run -- exactly the property we
/// cannot tolerate here.
///
/// The construction is FNV-1a's structure over 64-bit words with a stronger
/// finalizer (SplitMix64's). Byte order is little-endian by fiat; this project
/// targets Apple Silicon only, and pinning it keeps fixtures portable if that
/// ever changes.
public struct StateHasher: Sendable, BitwiseCopyable {
  @usableFromInline var accumulator: UInt64

  @usableFromInline static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
  @usableFromInline static let prime: UInt64 = 0x0000_0100_0000_01b3

  @inlinable
  public init() {
    accumulator = StateHasher.offsetBasis
  }

  /// Seeded start, for hashing independent shards that get combined later.
  @inlinable
  public init(seed: UInt64) {
    accumulator = StateHasher.offsetBasis ^ seed
  }

  @inlinable
  public mutating func combine(_ value: UInt64) {
    accumulator = (accumulator ^ value) &* StateHasher.prime
  }

  @inlinable
  public mutating func combine(_ value: UInt32) { combine(UInt64(value)) }

  @inlinable
  public mutating func combine(_ value: UInt16) { combine(UInt64(value)) }

  @inlinable
  public mutating func combine(_ value: UInt8) { combine(UInt64(value)) }

  @inlinable
  public mutating func combine(_ value: Int64) { combine(UInt64(bitPattern: value)) }

  @inlinable
  public mutating func combine(_ value: Int32) { combine(UInt64(bitPattern: Int64(value))) }

  @inlinable
  public mutating func combine(_ value: Int) { combine(UInt64(bitPattern: Int64(value))) }

  @inlinable
  public mutating func combine(_ value: Bool) { combine(UInt64(value ? 1 : 0)) }

  @inlinable
  public mutating func combine(_ value: Fixed) { combine(value.raw) }

  @inlinable
  public mutating func combine(_ value: Coord3) {
    combine(value.x)
    combine(value.y)
    combine(value.z)
  }

  @inlinable
  public mutating func combine(_ value: RNGStream) {
    // Stream position is part of sim state. Two runs that reached the same
    // fortress by consuming different numbers of draws have diverged, even
    // though nothing visible differs yet -- and they will visibly diverge on
    // the next roll. Catching it here catches it early.
    combine(value.state)
    combine(value.increment)
  }

  /// Folds in a whole buffer of trivial values.
  ///
  /// Reads through a raw byte view so that any `BitwiseCopyable` element type
  /// works without per-type hashing code. Padding bytes inside a struct would
  /// contribute garbage, so component types must not contain padding -- see
  /// `StateHasher.assertNoPadding`.
  @inlinable
  public mutating func combine<T: BitwiseCopyable>(buffer: UnsafeBufferPointer<T>) {
    guard let base = buffer.baseAddress, !buffer.isEmpty else {
      combine(UInt64(0))
      return
    }
    let byteCount = buffer.count * MemoryLayout<T>.stride
    let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(base), count: byteCount)
    combine(bytes: bytes)
  }

  @inlinable
  public mutating func combine(bytes: UnsafeRawBufferPointer) {
    var index = 0
    let wholeWords = bytes.count & ~7

    // Bulk path: eight bytes at a time, assembled explicitly rather than by
    // loading a UInt64 directly, because the buffer has no alignment
    // guarantee and unaligned loads are undefined behaviour in Swift.
    while index < wholeWords {
      var word: UInt64 = 0
      for offset in 0..<8 {
        word |= UInt64(bytes[index + offset]) << (offset * 8)
      }
      combine(word)
      index += 8
    }

    // Tail, length-prefixed so that trailing zero bytes are not silently
    // equivalent to no bytes at all.
    var tail: UInt64 = UInt64(bytes.count - index) << 56
    var shift = 0
    while index < bytes.count {
      tail |= UInt64(bytes[index]) << shift
      shift += 8
      index += 1
    }
    combine(tail)
  }

  /// The finalized 64-bit digest. SplitMix64's finalizer avalanches the
  /// accumulator so that a single changed byte moves roughly half the output
  /// bits -- FNV alone leaves the high bits sluggish.
  @inlinable
  public var value: UInt64 {
    var z = accumulator
    z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
    z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
    return z ^ (z >> 31)
  }

  /// Zero-padded hex, for fixtures and log output.
  public var hex: String {
    var digits = String(value, radix: 16)
    while digits.count < 16 { digits = "0" + digits }
    return digits
  }
}

/// Types that contribute to the per-tick state hash.
///
/// Conform every component and every piece of persistent sim state. A field
/// that is not hashed is a field that can drift between runs without any test
/// noticing, so `hash(into:)` should cover the whole struct -- if a field is
/// genuinely derived and not worth hashing, say why in a comment at the field.
public protocol StateHashable {
  func hash(into hasher: inout StateHasher)
}

extension StateHasher {
  @inlinable
  public mutating func combine<T: StateHashable>(_ value: T) {
    value.hash(into: &self)
  }

  /// Debug-only guard that a component type has no interior padding, which
  /// would otherwise feed uninitialized bytes into `combine(buffer:)` and
  /// produce hashes that differ between runs for no reason at all.
  ///
  /// Call from a test, not from sim code.
  public static func hasNoPadding<T: BitwiseCopyable>(_ type: T.Type, fieldByteCount: Int) -> Bool {
    MemoryLayout<T>.size == fieldByteCount && MemoryLayout<T>.stride == MemoryLayout<T>.size
  }
}

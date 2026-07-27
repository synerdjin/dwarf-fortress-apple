import DFCore
import Foundation

/// A recorded command stream plus the state hashes it produced.
///
/// This is the project's primary regression net. Replaying a fixture and
/// asserting its hash sequence turns "the simulation still behaves the same"
/// into a mechanical check that pinpoints the exact tick behaviour first
/// changed, rather than reporting that something, somewhere, is different.
///
/// The on-disk form is a fixed header followed by bulk copies of
/// `BitwiseCopyable` record arrays — the same bytes as in memory. There is no
/// encoder and no schema, so the serialized form cannot drift away from the
/// in-memory form, which is a class of bug that would silently invalidate every
/// fixture in the repository.
public struct Replay: Sendable {
  /// `"DFREPLAY"` as little-endian bytes.
  public static let magic: UInt64 = 0x5941_4C50_4552_4644
  public static let currentVersion: UInt32 = 1

  public var seed: UInt64
  public var mapSize: Coord3
  public var tickCount: UInt64
  /// Ticks between recorded hashes. 1 records every tick.
  public var hashInterval: UInt32
  public var commands: [TimedCommand]
  /// `(tick, hash)` checkpoints, ascending by tick.
  public var checkpoints: [Checkpoint]

  public struct Checkpoint: Sendable, BitwiseCopyable, Equatable {
    public var tick: UInt64
    public var hash: UInt64

    public init(tick: UInt64, hash: UInt64) {
      self.tick = tick
      self.hash = hash
    }
  }

  public init(
    seed: UInt64,
    mapSize: Coord3,
    tickCount: UInt64,
    hashInterval: UInt32,
    commands: [TimedCommand],
    checkpoints: [Checkpoint]
  ) {
    self.seed = seed
    self.mapSize = mapSize
    self.tickCount = tickCount
    self.hashInterval = hashInterval
    self.commands = commands
    self.checkpoints = checkpoints
  }

  // MARK: - Encoding

  public func encoded() -> Data {
    var data = Data()
    data.appendLittleEndian(Replay.magic)
    data.appendLittleEndian(Replay.currentVersion)
    data.appendLittleEndian(seed)
    data.appendLittleEndian(UInt32(bitPattern: mapSize.x))
    data.appendLittleEndian(UInt32(bitPattern: mapSize.y))
    data.appendLittleEndian(UInt32(bitPattern: mapSize.z))
    data.appendLittleEndian(tickCount)
    data.appendLittleEndian(hashInterval)
    data.appendLittleEndian(UInt32(commands.count))
    data.appendLittleEndian(UInt32(checkpoints.count))
    commands.withUnsafeBufferPointer { data.append(bulk: $0) }
    checkpoints.withUnsafeBufferPointer { data.append(bulk: $0) }
    return data
  }

  public enum DecodeError: Error, CustomStringConvertible {
    case tooShort
    case badMagic
    case unsupportedVersion(UInt32)
    case truncated(expected: Int, got: Int)

    public var description: String {
      switch self {
      case .tooShort: "replay file is too short to contain a header"
      case .badMagic: "not a replay file (bad magic)"
      case .unsupportedVersion(let version): "unsupported replay version \(version)"
      case .truncated(let expected, let got):
        "replay file truncated: expected \(expected) bytes of records, found \(got)"
      }
    }
  }

  public init(decoding data: Data) throws {
    let headerSize = 8 + 4 + 8 + 12 + 8 + 4 + 4 + 4
    guard data.count >= headerSize else { throw DecodeError.tooShort }

    var cursor = 0
    func read<T: FixedWidthInteger>(_ type: T.Type) -> T {
      let value = data.littleEndian(T.self, at: cursor)
      cursor += MemoryLayout<T>.size
      return value
    }

    guard read(UInt64.self) == Replay.magic else { throw DecodeError.badMagic }
    let version = read(UInt32.self)
    guard version == Replay.currentVersion else {
      throw DecodeError.unsupportedVersion(version)
    }
    seed = read(UInt64.self)
    mapSize = Coord3(
      Int32(bitPattern: read(UInt32.self)),
      Int32(bitPattern: read(UInt32.self)),
      Int32(bitPattern: read(UInt32.self))
    )
    tickCount = read(UInt64.self)
    hashInterval = read(UInt32.self)
    let commandCount = Int(read(UInt32.self))
    let checkpointCount = Int(read(UInt32.self))

    let commandBytes = commandCount * MemoryLayout<TimedCommand>.stride
    let checkpointBytes = checkpointCount * MemoryLayout<Checkpoint>.stride
    let available = data.count - cursor
    guard available >= commandBytes + checkpointBytes else {
      throw DecodeError.truncated(expected: commandBytes + checkpointBytes, got: available)
    }

    commands = data.bulk(TimedCommand.self, at: cursor, count: commandCount)
    cursor += commandBytes
    checkpoints = data.bulk(Checkpoint.self, at: cursor, count: checkpointCount)
  }

  // MARK: - File IO

  public func write(to path: String) throws {
    try encoded().write(to: URL(fileURLWithPath: path))
  }

  public static func read(from path: String) throws -> Replay {
    try Replay(decoding: Data(contentsOf: URL(fileURLWithPath: path)))
  }
}

// MARK: - Data helpers

extension Data {
  fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var little = value.littleEndian
    Swift.withUnsafeBytes(of: &little) { self.append(contentsOf: $0) }
  }

  fileprivate mutating func append<T: BitwiseCopyable>(bulk buffer: UnsafeBufferPointer<T>) {
    guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
    append(
      UnsafeBufferPointer<UInt8>(
        start: UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self),
        count: buffer.count * MemoryLayout<T>.stride
      )
    )
  }

  fileprivate func littleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
    // Assembled byte by byte rather than loaded directly: `Data`'s storage
    // carries no alignment guarantee, and an unaligned typed load is undefined.
    var value: T = 0
    for index in 0..<MemoryLayout<T>.size {
      value |= T(self[startIndex + offset + index]) << (index * 8)
    }
    return value
  }

  fileprivate func bulk<T: BitwiseCopyable>(_ type: T.Type, at offset: Int, count: Int)
    -> [T]
  {
    guard count > 0 else { return [] }
    let byteCount = count * MemoryLayout<T>.stride
    var bytes = [UInt8](repeating: 0, count: byteCount)
    bytes.withUnsafeMutableBytes { destination in
      self.copyBytes(
        to: destination,
        from: (startIndex + offset)..<(startIndex + offset + byteCount)
      )
    }
    return bytes.withUnsafeBytes { raw in
      Array(
        UnsafeBufferPointer(start: raw.baseAddress!.assumingMemoryBound(to: T.self), count: count))
    }
  }
}

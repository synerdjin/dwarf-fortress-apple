import DFCore
import DFECS

/// What a command asks the simulation to do.
///
/// Raw values are frozen: they are written into replay fixtures.
public enum CommandKind: UInt8, Sendable, BitwiseCopyable, CaseIterable {
  case noop = 0
  /// Mark a region with a designation.
  case designate = 1
  /// Clear designations in a region.
  case clearDesignation = 2
  /// Add a dwarf at the region's origin.
  case spawnDwarf = 3
}

/// The only way simulation state changes (Constitution III).
///
/// Deliberately a **fixed-size, `BitwiseCopyable` struct** rather than an enum
/// with associated values. Recording a replay is then a bulk write of a command
/// array and reading one is a bulk read, with no encoder, no schema, and no
/// opportunity for the serialized form to drift away from the in-memory form.
/// The cost is a few unused bytes per command, which is nothing next to a
/// replay format that can silently disagree with itself.
///
/// Layout is 32 bytes with explicit padding, so no uninitialized byte ever
/// reaches the hash or the file.
public struct Command: PlainData, Equatable {
  public var kind: CommandKind
  public var designation: Designation
  /// Explicit, always zero. Named rather than implicit so the struct has no
  /// compiler-inserted padding.
  public var reserved: UInt16
  /// Kind-specific payload: creature count, designation priority, and so on.
  public var value: UInt32
  /// The affected area. Single-tile commands use a 1×1×1 region.
  public var region: Region3

  @inlinable
  public init(
    kind: CommandKind,
    region: Region3 = Region3(origin: .zero, size: Coord3(1, 1, 1)),
    designation: Designation = .none,
    value: UInt32 = 0
  ) {
    self.kind = kind
    self.designation = designation
    self.reserved = 0
    self.value = value
    self.region = region
  }

  public static func designate(_ region: Region3, _ designation: Designation) -> Command {
    Command(kind: .designate, region: region, designation: designation)
  }

  public static func clearDesignation(_ region: Region3) -> Command {
    Command(kind: .clearDesignation, region: region)
  }

  public static func spawnDwarf(at coord: Coord3) -> Command {
    Command(kind: .spawnDwarf, region: Region3(origin: coord, size: Coord3(1, 1, 1)))
  }

  public func hash(into hasher: inout StateHasher) {
    hasher.combine(kind.rawValue)
    hasher.combine(designation.rawValue)
    hasher.combine(reserved)
    hasher.combine(value)
    hasher.combine(region.origin)
    hasher.combine(region.size)
  }
}

/// A command paired with the tick it is applied on.
public struct TimedCommand: PlainData, Equatable {
  public var tick: UInt64
  public var command: Command

  @inlinable
  public init(tick: UInt64, command: Command) {
    self.tick = tick
    self.command = command
  }

  public func hash(into hasher: inout StateHasher) {
    hasher.combine(tick)
    command.hash(into: &hasher)
  }
}

/// Commands awaiting application, plus the recording of everything applied.
///
/// The queue drains in submission order every tick. Producers (UI, input, AI)
/// never touch simulation state directly; they enqueue here and the tick loop
/// consumes.
public struct CommandQueue: Sendable {
  private var pending: [Command] = []
  /// Everything ever applied, with its tick. This *is* the replay.
  public private(set) var recording: [TimedCommand] = []
  /// Whether to retain a recording. Off during replay playback, where the
  /// input already exists and re-recording would just double memory.
  public var isRecording: Bool

  public init(isRecording: Bool = true) {
    self.isRecording = isRecording
  }

  public mutating func submit(_ command: Command) {
    pending.append(command)
  }

  public var pendingCount: Int { pending.count }

  /// Removes and returns this tick's commands, in submission order.
  public mutating func drain(tick: UInt64) -> [Command] {
    guard !pending.isEmpty else { return [] }
    let commands = pending
    pending.removeAll(keepingCapacity: true)
    if isRecording {
      recording.append(contentsOf: commands.map { TimedCommand(tick: tick, command: $0) })
    }
    return commands
  }

  public mutating func clearRecording() {
    recording.removeAll(keepingCapacity: false)
  }

  /// Folds the **pending** queue into the tick hash.
  ///
  /// Pending commands are future-affecting state: two fortresses identical in
  /// every other respect but holding different undrained commands will diverge
  /// on the next `step()`. Leaving them out meant `Fortress.stateHash` could
  /// certify as equal two states that were about to stop being equal, which is
  /// the one thing the digest exists to prevent.
  ///
  /// `recording` is deliberately excluded. It is an append-only log of what has
  /// already been applied and cannot influence any future tick -- and it is
  /// present or absent depending on `isRecording`, which is true while
  /// recording a fixture and false while replaying one. Hashing it would make
  /// every replay disagree with the run it replays.
  public func hash(into hasher: inout StateHasher) {
    hasher.combine(pending.count)
    for command in pending {
      command.hash(into: &hasher)
    }
  }
}

import DFCore

/// A reproducible fortress setup, used by `bench`, `record` and the fixtures.
///
/// Scenarios are code rather than data so they can be referred to by name from
/// the CLI and from tests without a content pipeline that does not exist yet.
/// When the raws compiler lands in M4 these become data.
public struct Scenario: Sendable {
  public let name: String
  public let mapSize: Coord3
  public let dwarfCount: Int
  /// Commands issued at tick 0 beyond the dwarf spawns.
  public let setup: @Sendable (Coord3) -> [Command]

  public init(
    name: String,
    mapSize: Coord3,
    dwarfCount: Int,
    setup: @escaping @Sendable (Coord3) -> [Command]
  ) {
    self.name = name
    self.mapSize = mapSize
    self.dwarfCount = dwarfCount
    self.setup = setup
  }

  /// Every command this scenario issues at tick 0, dwarf spawns included.
  ///
  /// Spawns come first and in a fixed order, so entity slot assignment — and
  /// therefore every component array's layout — is identical on every run.
  public func initialCommands() -> [Command] {
    let top = mapSize.z - 1
    var commands: [Command] = []
    for index in 0..<dwarfCount {
      // Spread along the top row deterministically.
      let x = Int32(index % Int(mapSize.x))
      let y = Int32(index / Int(mapSize.x)) % mapSize.y
      commands.append(.spawnDwarf(at: Coord3(x, y, top)))
    }
    commands.append(contentsOf: setup(mapSize))
    return commands
  }

  public static let all: [Scenario] = [smallDig, twoHundredDwarves]

  public static func named(_ name: String) -> Scenario? {
    all.first { $0.name == name }
  }

  /// A handful of dwarves digging a room. Small enough to read as ASCII.
  public static let smallDig = Scenario(
    name: "small-dig",
    mapSize: Coord3(64, 48, 8),
    dwarfCount: 4
  ) { size in
    let top = size.z - 1
    return [
      .designate(
        Region3(origin: Coord3(10, 10, top - 1), size: Coord3(20, 12, 1)),
        .dig
      )
    ]
  }

  /// The plan's headline scale: 200 dwarves on a 3×3-embark-sized map.
  public static let twoHundredDwarves = Scenario(
    name: "200-dwarves",
    mapSize: Coord3(144, 144, 16),
    dwarfCount: 200
  ) { size in
    let top = size.z - 1
    // Several dig sites so miners spread out rather than queueing on one tile.
    return (0..<4).map { index in
      let originX = Int32(16 + (index % 2) * 60)
      let originY = Int32(16 + (index / 2) * 60)
      return .designate(
        Region3(origin: Coord3(originX, originY, top - 1), size: Coord3(40, 40, 1)),
        .dig
      )
    }
  }
}

extension Fortress {
  /// Builds a fortress from a scenario, with its tick-0 commands submitted but
  /// not yet applied.
  public static func make(
    scenario: Scenario,
    seed: UInt64,
    jobs: JobSystem,
    isRecording: Bool = true
  ) -> Fortress {
    let fortress = Fortress(
      seed: seed,
      mapSize: scenario.mapSize,
      jobs: jobs,
      isRecording: isRecording
    )
    for command in scenario.initialCommands() {
      fortress.submit(command)
    }
    return fortress
  }

  /// Runs `ticks`, capturing a hash every `hashInterval` ticks.
  ///
  /// The checkpoint at tick 0 is taken *after* the tick-0 commands are applied,
  /// so a fixture that disagrees about setup fails immediately rather than
  /// drifting into disagreement later.
  public func runCapturingHashes(ticks: Int, hashInterval: Int) -> [Replay.Checkpoint] {
    var checkpoints: [Replay.Checkpoint] = []
    for index in 0..<ticks {
      step()
      if index % hashInterval == 0 || index == ticks - 1 {
        checkpoints.append(Replay.Checkpoint(tick: tick, hash: stateHash))
      }
    }
    return checkpoints
  }
}

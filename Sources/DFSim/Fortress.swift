import DFCore
import DFECS

/// Where a creature is.
public struct Position: Component {
  public var coord: Coord3

  @inlinable
  public init(_ coord: Coord3) { self.coord = coord }

  public func hash(into hasher: inout StateHasher) {
    hasher.combine(coord)
  }
}

/// A creature that digs.
///
/// M0 keeps this deliberately thin — enough to exercise commands, the map, the
/// job system and the hash. Real labours, skills and needs arrive in M4/M5.
public struct Miner: Component {
  /// Tile currently being dug, or `nil` encoded as an out-of-range coord.
  public var target: Coord3
  /// Whether `target` is meaningful.
  public var hasTarget: Bool
  /// Ticks of work remaining on `target`.
  public var progress: UInt16
  /// Explicit padding so the struct has no compiler-inserted holes.
  public var reserved: UInt8

  @inlinable
  public init() {
    target = .zero
    hasTarget = false
    progress = 0
    reserved = 0
  }

  /// Ticks to dig one tile. Arbitrary for M0; M4 derives it from skill and
  /// material hardness.
  public static let ticksPerTile: UInt16 = 40

  public func hash(into hasher: inout StateHasher) {
    hasher.combine(target)
    hasher.combine(hasTarget)
    hasher.combine(progress)
    hasher.combine(reserved)
  }
}

/// A running fortress: map, entities, RNG streams, and the tick pipeline.
///
/// Everything that constitutes simulation state lives here and folds into
/// `stateHash`. Anything that does not fold in is, by definition, not state —
/// and if it influences behaviour anyway, replay will diverge and the hash will
/// say so at the tick it first mattered.
public final class Fortress: @unchecked Sendable {
  public let world: World
  public let map: MapStore
  public let scheduler: TickScheduler
  public var commands: CommandQueue

  public let seed: UInt64
  /// Per-domain streams. Part of state: their positions are hashed.
  var jobRNG: RNGStream
  var pathRNG: RNGStream

  public private(set) var tick: UInt64 = 0

  public init(seed: UInt64, mapSize: Coord3, jobs: JobSystem, isRecording: Bool = true) {
    self.seed = seed
    self.world = World()
    self.map = MapStore(size: mapSize)
    self.scheduler = TickScheduler(jobs: jobs)
    self.commands = CommandQueue(isRecording: isRecording)
    self.jobRNG = RNGStream(seed: seed, .jobSelection)
    self.pathRNG = RNGStream(seed: seed, .pathTieBreak)

    world.register(Position.self)
    world.register(Miner.self)
    registerSystems()
    carveInitialSurface()
  }

  // MARK: - Setup

  /// Opens the topmost z-level so spawned dwarves have somewhere to stand.
  private func carveInitialSurface() {
    let top = map.size.z - 1
    map.fill(
      Region3(origin: Coord3(0, 0, top), size: Coord3(map.size.x, map.size.y, 1)),
      with: Tile(type: .floor, material: .soil, flags: [.outside, .light])
    )
  }

  private func registerSystems() {
    // Movement: each miner steps toward its target. Writes only its own
    // Position, so partitions touch disjoint slots.
    scheduler.register(
      SystemDescriptor(
        name: "miner-movement",
        phase: .movement,
        reads: [Miner.self],
        writes: [Position.self]
      ) { [weak self] world, jobs in
        self?.runMovement(world: world, jobs: jobs)
      }
    )

    // Mining: miners adjacent to their target make progress and, on
    // completion, dig it out. Digging mutates the shared map, so the work is
    // gathered into per-partition scratch and applied in partition order.
    scheduler.register(
      SystemDescriptor(
        name: "mining",
        phase: .jobs,
        reads: [Position.self],
        writes: [Miner.self]
      ) { [weak self] world, jobs in
        self?.runMining(world: world, jobs: jobs)
      }
    )
  }

  // MARK: - Commands

  public func submit(_ command: Command) {
    commands.submit(command)
  }

  /// Applies one command. The only place map and entity state is created.
  private func apply(_ command: Command) {
    switch command.kind {
    case .noop:
      break

    case .designate:
      command.region.clamped(to: map.bounds).forEach { coord in
        guard map[coord].type.isMineable else { return }
        map.modifyTile(coord) { $0.designation = command.designation }
      }

    case .clearDesignation:
      command.region.clamped(to: map.bounds).forEach { coord in
        map.modifyTile(coord) { $0.designation = .none }
      }

    case .spawnDwarf:
      let entity = world.createEntity()
      world.set(Position(command.region.origin), on: entity)
      world.set(Miner(), on: entity)
    }
  }

  // MARK: - Tick

  public func step() {
    for command in commands.drain(tick: tick) {
      apply(command)
    }
    scheduler.tick(world)
    tick += 1
  }

  public func run(ticks: Int) {
    for _ in 0..<ticks { step() }
  }

  // MARK: - Systems

  private func runMovement(world: World, jobs: JobSystem) {
    let miners = world.storage(Miner.self)
    let positions = world.storage(Position.self)
    guard miners.componentCount > 0 else { return }

    positions.withDense { values, owners in
      nonisolated(unsafe) let slots = values
      nonisolated(unsafe) let entities = owners
      jobs.parallelFor(0..<slots.count) { range, _ in
        for index in range {
          guard let miner = miners[entities[index]], miner.hasTarget else { continue }
          let current = slots[index].coord
          let target = miner.target
          guard current != target else { continue }
          // One step, greedily, on each axis. Real pathfinding is M6; this is
          // enough to move dwarves deterministically toward work.
          let step = Coord3(
            current.x + signum(target.x - current.x),
            current.y + signum(target.y - current.y),
            current.z + signum(target.z - current.z)
          )
          slots[index].coord = step
        }
      }
    }
  }

  private func runMining(world: World, jobs: JobSystem) {
    let miners = world.storage(Miner.self)
    let positions = world.storage(Position.self)
    guard miners.componentCount > 0 else { return }

    // Target assignment reads the map and draws from an RNG stream, so it runs
    // serially in entity order. Parallelising it would mean the order of RNG
    // draws depended on partitioning -- the exact coupling Constitution II
    // exists to prevent.
    var completed: [Coord3] = []
    miners.withDense { values, owners in
      for index in 0..<values.count {
        let entity = owners[index]
        guard let position = positions[entity]?.coord else { continue }

        if !values[index].hasTarget {
          if let target = findDigTarget(near: position) {
            values[index].target = target
            values[index].hasTarget = true
            values[index].progress = Miner.ticksPerTile
          }
          continue
        }

        let target = values[index].target
        // The tile may have been dug by someone else, or the designation
        // cancelled, since this target was chosen.
        guard map[target].designation == .dig, map[target].type.isMineable else {
          values[index].hasTarget = false
          values[index].progress = 0
          continue
        }
        guard position.chebyshevDistance(to: target) <= 1 else { continue }

        if values[index].progress > 0 {
          values[index].progress -= 1
        }
        if values[index].progress == 0 {
          completed.append(target)
          values[index].hasTarget = false
        }
      }
    }

    for coord in completed {
      map.setTile(
        coord,
        Tile(type: .floor, material: map[coord].material, flags: map[coord].flags)
      )
    }
  }

  /// Nearest designated tile within a bounded search box.
  ///
  /// Ties break by row-major coordinate order rather than by whichever tile the
  /// scan happens to reach first, so the choice does not depend on scan
  /// direction.
  private func findDigTarget(near origin: Coord3) -> Coord3? {
    let radius: Int32 = 24
    let search = Region3(
      origin: Coord3(origin.x - radius, origin.y - radius, origin.z - 1),
      size: Coord3(radius * 2 + 1, radius * 2 + 1, 3)
    ).clamped(to: map.bounds)

    var best: Coord3?
    var bestDistance = Int32.max
    search.forEach { coord in
      guard map[coord].designation == .dig, map[coord].type.isMineable else { return }
      let distance = origin.chebyshevDistance(to: coord)
      if distance < bestDistance || (distance == bestDistance && best.map { coord < $0 } == true) {
        best = coord
        bestDistance = distance
      }
    }
    return best
  }

  // MARK: - Hashing

  /// The digest replay assertions compare.
  public func hash(into hasher: inout StateHasher) {
    hasher.combine(tick)
    hasher.combine(seed)
    hasher.combine(jobRNG)
    hasher.combine(pathRNG)
    world.hash(into: &hasher)
    map.hash(into: &hasher)
  }

  public var stateHash: UInt64 {
    var hasher = StateHasher()
    hash(into: &hasher)
    return hasher.value
  }

  /// One z-level as text, for `dfsim ascii`.
  public func ascii(z: Int32) -> String {
    var output = map.asciiSlice(z: z)
    guard !output.isEmpty else { return output }

    // Overlay creatures so the map shows who is where.
    var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(Array.init)
    world.storage(Position.self).withDense { values, _ in
      for index in 0..<values.count {
        let coord = values[index].coord
        guard coord.z == z, coord.y >= 0, Int(coord.y) < lines.count,
          coord.x >= 0, Int(coord.x) < lines[Int(coord.y)].count
        else { continue }
        lines[Int(coord.y)][Int(coord.x)] = "☺"
      }
    }
    output = lines.map { String($0) }.joined(separator: "\n")
    return output
  }
}

@inlinable
func signum(_ value: Int32) -> Int32 {
  value > 0 ? 1 : (value < 0 ? -1 : 0)
}

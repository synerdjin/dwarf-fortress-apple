import DFCore

/// The ordered stages of a simulation tick.
///
/// Phase order is the backbone of the tick and is deliberately explicit rather
/// than derived from dependencies: a scheduler that infers order from declared
/// components would reorder itself as systems are added, and every replay
/// fixture would shift underneath us. Adding a phase is a spec change.
///
/// Raw values are frozen for the same reason RNG domains are.
public enum TickPhase: Int, Sendable, CaseIterable, Comparable {
  /// Calendar advance, season and weather rollover.
  case time = 0
  /// Temperature diffusion, material state change.
  case environment = 100
  /// Water and magma flow, pressure, cave-ins.
  case fluids = 200
  /// Plant growth, farming, rot and wear.
  case growth = 300
  /// Path requests, movement, position updates.
  case movement = 400
  /// Needs, thoughts, personality, mood.
  case minds = 500
  /// Labour assignment, hauling, work orders.
  case jobs = 600
  /// Workshops and reactions producing items.
  case production = 700
  /// Combat resolution and wounds.
  case combat = 800
  /// Births, deaths, migration, sieges, caravans.
  case population = 900
  /// Announcements, logging, and any deferred structural changes.
  case bookkeeping = 1000

  public static func < (lhs: TickPhase, rhs: TickPhase) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// A registered simulation system.
///
/// The declared `reads` and `writes` are not documentation. In debug builds the
/// scheduler records which component storages a system actually touches and
/// fails loudly if it exceeded its declaration. That converts the worst class
/// of bug in this codebase -- an undeclared write that races or reorders under
/// parallelism -- from a heisenbug found in month six into a startup failure
/// found in the first run.
public struct SystemDescriptor: Sendable {
  public let name: String
  public let phase: TickPhase
  /// Component types this system reads.
  public let reads: Set<ObjectIdentifier>
  /// Component types this system writes.
  public let writes: Set<ObjectIdentifier>
  /// Human-readable names, for error messages.
  public let typeNames: [ObjectIdentifier: String]

  let run: @Sendable (World, JobSystem) -> Void

  public init(
    name: String,
    phase: TickPhase,
    reads: [any Component.Type] = [],
    writes: [any Component.Type] = [],
    run: @escaping @Sendable (World, JobSystem) -> Void
  ) {
    self.name = name
    self.phase = phase
    self.reads = Set(reads.map { ObjectIdentifier($0) })
    self.writes = Set(writes.map { ObjectIdentifier($0) })
    var names: [ObjectIdentifier: String] = [:]
    for type in reads { names[ObjectIdentifier(type)] = String(describing: type) }
    for type in writes { names[ObjectIdentifier(type)] = String(describing: type) }
    self.typeNames = names
    self.run = run
  }

  /// Everything the system is permitted to touch.
  var declaredTypes: Set<ObjectIdentifier> { reads.union(writes) }
}

/// Runs systems in phase order, once per tick.
///
/// Systems within a phase run sequentially in registration order; a system that
/// wants parallelism gets it internally from `JobSystem`. This is a deliberate
/// simplification over auto-parallelising across systems: within-system
/// parallelism is where the actual work is (scanning 100k tiles), and
/// cross-system parallelism would buy little while making the execution order
/// -- and therefore the state hash -- depend on a scheduling heuristic.
public final class TickScheduler: @unchecked Sendable {
  private var systems: [SystemDescriptor] = []
  private let jobs: JobSystem

  /// Ticks executed since construction. Part of sim state.
  public private(set) var tickCount: UInt64 = 0

  public init(jobs: JobSystem) {
    self.jobs = jobs
  }

  /// Registers a system. Registration order decides execution order within a
  /// phase, so it must not depend on iteration over an unordered collection.
  public func register(_ system: SystemDescriptor) {
    precondition(
      !systems.contains { $0.name == system.name },
      "system '\(system.name)' registered twice"
    )
    systems.append(system)
    // Stable sort by phase preserves registration order inside each phase.
    systems.sort { lhs, rhs in lhs.phase.rawValue < rhs.phase.rawValue }
  }

  public var registeredSystems: [SystemDescriptor] { systems }

  /// Systems in execution order, as `phase/name` strings. Printed by
  /// `dfsim systems` so the tick pipeline can be inspected without reading code.
  public var executionOrder: [String] {
    systems.map { "\($0.phase)/\($0.name)" }
  }

  /// Runs one tick: every system, in phase order.
  public func tick(_ world: World) {
    for system in systems {
      #if DEBUG
        world.activeSystem = system
        world.accessedTypes = []
        world.accessedTypeNames = [:]
      #endif

      system.run(world, jobs)

      #if DEBUG
        validateAccess(of: system, in: world)
        world.activeSystem = nil
      #endif
    }
    tickCount += 1
  }

  public func run(_ world: World, ticks: Int) {
    for _ in 0..<ticks { tick(world) }
  }

  #if DEBUG
    /// Fails if a system touched a component type it did not declare.
    ///
    /// Only over-access is detectable this way: a system that declares a write
    /// and never performs it is wasteful but harmless, while a system that
    /// writes something undeclared is a latent ordering bug.
    private func validateAccess(of system: SystemDescriptor, in world: World) {
      let undeclared = world.accessedTypes.subtracting(system.declaredTypes)
      guard !undeclared.isEmpty else { return }
      let names =
        undeclared
        .map { world.accessedTypeNames[$0] ?? "\($0)" }
        .sorted()
        .joined(separator: ", ")
      preconditionFailure(
        """
        system '\(system.name)' touched undeclared component types: \(names).
        Add them to the system's reads/writes, or stop touching them. \
        Undeclared access is how ordering bugs get in.
        """
      )
    }
  #endif
}

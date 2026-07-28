import DFCore
import DFECS
import DFRender
import DFSim
import DFUI
import Darwin
import Foundation

// The headless driver. Constitution V: every module ships a verb here, because
// a subsystem that can only be exercised by launching the app and looking at it
// is a subsystem an agent cannot verify.
//
// Argument parsing is hand-rolled rather than pulled from swift-argument-parser:
// hermetic offline builds are a project property, and this is sixty lines.

struct Arguments {
  let verb: String
  private let flags: [String: String]
  let positional: [String]

  init(_ raw: [String]) {
    var flags: [String: String] = [:]
    var positional: [String] = []
    var index = 0
    verb = raw.first ?? "help"
    let rest = Array(raw.dropFirst())

    while index < rest.count {
      let token = rest[index]
      if token.hasPrefix("--") {
        let name = String(token.dropFirst(2))
        if let equals = name.firstIndex(of: "=") {
          flags[String(name[name.startIndex..<equals])] = String(name[name.index(after: equals)...])
        } else if index + 1 < rest.count && !rest[index + 1].hasPrefix("--") {
          flags[name] = rest[index + 1]
          index += 1
        } else {
          flags[name] = "true"
        }
      } else {
        positional.append(token)
      }
      index += 1
    }
    self.flags = flags
    self.positional = positional
  }

  func string(_ name: String, default fallback: String? = nil) -> String? {
    flags[name] ?? fallback
  }

  func int(_ name: String, default fallback: Int) -> Int {
    flags[name].flatMap(Int.init) ?? fallback
  }

  func uint64(_ name: String, default fallback: UInt64) -> UInt64 {
    flags[name].flatMap(UInt64.init) ?? fallback
  }

  func bool(_ name: String) -> Bool {
    flags[name] == "true"
  }

  func intList(_ name: String, default fallback: [Int]) -> [Int] {
    guard let raw = flags[name] else { return fallback }
    return raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
  }
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("error: \(message)\n".utf8))
  exit(1)
}

func resolveScenario(_ name: String) -> Scenario {
  guard let scenario = Scenario.named(name) else {
    fail(
      "unknown scenario '\(name)'. Available: \(Scenario.all.map(\.name).joined(separator: ", "))")
  }
  return scenario
}

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))

switch arguments.verb {

// MARK: - ascii

case "ascii":
  // How an agent *looks at* the game.
  let scenario = resolveScenario(arguments.string("scenario", default: "small-dig")!)
  let seed = arguments.uint64("seed", default: 1)
  let ticks = arguments.int("tick", default: 0)
  let z = Int32(arguments.int("z", default: Int(scenario.mapSize.z) - 2))

  let fortress = Fortress.make(scenario: scenario, seed: seed, jobs: JobSystem())
  fortress.run(ticks: ticks)

  print("scenario \(scenario.name)  seed \(seed)  tick \(fortress.tick)  z \(z)")
  print("hash \(String(fortress.stateHash, radix: 16))")
  print(fortress.ascii(z: z), terminator: "")

// MARK: - record

case "record":
  let scenario = resolveScenario(arguments.string("scenario", default: "small-dig")!)
  let seed = arguments.uint64("seed", default: 1)
  let ticks = arguments.int("ticks", default: 10000)
  let interval = arguments.int("hash-interval", default: 100)
  guard let output = arguments.string("out") else { fail("record requires --out <path>") }

  let fortress = Fortress.make(scenario: scenario, seed: seed, jobs: JobSystem())
  let checkpoints = fortress.runCapturingHashes(ticks: ticks, hashInterval: interval)

  let replay = Replay(
    seed: seed,
    mapSize: scenario.mapSize,
    tickCount: UInt64(ticks),
    hashInterval: UInt32(interval),
    commands: fortress.commands.recording,
    checkpoints: checkpoints
  )
  do {
    try replay.write(to: output)
  } catch {
    fail("could not write \(output): \(error)")
  }
  print(
    "recorded \(ticks) ticks, \(replay.commands.count) commands, "
      + "\(checkpoints.count) checkpoints -> \(output)"
  )
  print("final hash \(String(fortress.stateHash, radix: 16))")

// MARK: - replay

case "replay":
  guard let path = arguments.positional.first else {
    fail("replay requires a fixture path")
  }
  let assert = arguments.bool("assert-hashes")
  let threads = arguments.int("threads", default: 0)

  let replay: Replay
  do {
    replay = try Replay.read(from: path)
  } catch {
    fail("\(error)")
  }

  let jobs = JobSystem(
    forceSerial: threads == 1,
    partitionCountOverride: threads > 0 ? threads : nil
  )
  let fortress = Fortress(
    seed: replay.seed,
    mapSize: replay.mapSize,
    jobs: jobs,
    isRecording: false
  )

  // Commands are grouped by tick and replayed in recorded order.
  var byTick: [UInt64: [Command]] = [:]
  for entry in replay.commands {
    byTick[entry.tick, default: []].append(entry.command)
  }

  var expected: [UInt64: UInt64] = [:]
  for checkpoint in replay.checkpoints { expected[checkpoint.tick] = checkpoint.hash }

  var mismatches = 0
  var firstMismatch: (tick: UInt64, expected: UInt64, actual: UInt64)?

  for _ in 0..<replay.tickCount {
    for command in byTick[fortress.tick] ?? [] {
      fortress.submit(command)
    }
    fortress.step()

    if assert, let want = expected[fortress.tick] {
      let got = fortress.stateHash
      if got != want {
        mismatches += 1
        if firstMismatch == nil {
          firstMismatch = (fortress.tick, want, got)
        }
      }
    }
  }

  if assert {
    if let first = firstMismatch {
      print("FAIL: \(mismatches) of \(replay.checkpoints.count) checkpoints diverged")
      print(
        "first divergence at tick \(first.tick): expected "
          + "\(String(first.expected, radix: 16)), got \(String(first.actual, radix: 16))"
      )
      exit(1)
    }
    print("OK: \(replay.checkpoints.count) checkpoints matched over \(replay.tickCount) ticks")
  } else {
    print("replayed \(replay.tickCount) ticks, final hash \(String(fortress.stateHash, radix: 16))")
  }

// MARK: - determinism-check

case "determinism-check":
  // The gate. Identical commands must produce identical hashes regardless of
  // how the work was partitioned across workers.
  let scenario = resolveScenario(arguments.string("scenario", default: "small-dig")!)
  let seed = arguments.uint64("seed", default: 1)
  let ticks = arguments.int("ticks", default: 2000)
  // 1,2,4 is the decomposition an agent naturally reaches for, and it is the
  // one a bug is least likely to survive being caught by: every count is a
  // power of two, so a partition boundary that only misbehaves when the work
  // does not divide evenly never gets exercised. 3 and 7 make the last
  // partition ragged; 16 and 64 exceed the core count on every machine this
  // targets, so partitions become smaller than a work item and some end up
  // empty. Determinism must not depend on any of that.
  let threadCounts = arguments.intList("threads", default: [1, 2, 3, 7, 16, 64])

  var results: [(threads: Int, hash: UInt64)] = []
  for count in threadCounts {
    let jobs = JobSystem(forceSerial: count == 1, partitionCountOverride: count)
    let fortress = Fortress.make(scenario: scenario, seed: seed, jobs: jobs, isRecording: false)
    // Partition count is what actually varies the decomposition; a correct
    // system is invariant to it.
    fortress.run(ticks: ticks)
    results.append((count, fortress.stateHash))
  }

  let reference = results[0].hash
  let diverged = results.filter { $0.hash != reference }
  for result in results {
    let mark = result.hash == reference ? "OK  " : "FAIL"
    print("\(mark) threads=\(result.threads)  hash=\(String(result.hash, radix: 16))")
  }
  if diverged.isEmpty {
    print("OK: \(scenario.name) is deterministic across \(threadCounts) over \(ticks) ticks")
  } else {
    print("FAIL: \(diverged.count) thread counts diverged from the serial reference")
    exit(1)
  }

// MARK: - bench

case "bench":
  let scenario = resolveScenario(arguments.string("scenario", default: "200-dwarves")!)
  let seed = arguments.uint64("seed", default: 1)
  let ticks = arguments.int("ticks", default: 10000)
  let budget = arguments.string("budget-ms").flatMap(Double.init)

  // PC-002: does publishing a snapshot every tick add more than 1 ms/tick?
  // Measured by running the same scenario with the work switched on, because
  // the requirement is about the delta a window imposes, not absolute cost.
  let withSnapshot = arguments.bool("with-snapshot")
  // Deliberately NOT clamped to the map. An earlier version clamped with an
  // inline `min`, on a comment claiming parity with `CameraController` -- which
  // is false: the controller clamps the camera's *origin* to the map but never
  // its *size*. So the clamp made this gate measure a camera the shipped window
  // never produces, and excluded exactly the empty-space cost a real window
  // pays. Pick a viewport that fits the map (render-300x200 exists for this)
  // rather than hiding the overhang behind a clamp.
  let renderCamera = Camera(
    origin: Coord3(0, 0, Int32(scenario.mapSize.z) - 2),
    size: Coord3(
      Int32(arguments.int("width", default: 300)),
      Int32(arguments.int("height", default: 200)),
      1),
    depthLayers: arguments.int("layers", default: 4))

  /// One measured run. Returns ms/tick and the fortress it measured.
  ///
  /// Drives `SimulationHost` rather than re-implementing its loop. That is not
  /// tidiness: the host owns the `SnapshotCache` that makes PC-002 hold, and a
  /// bench that hand-rolled the loop would measure a path nothing else uses.
  func measure(publishingSnapshots: Bool) -> (msPerTick: Double, fortress: Fortress) {
    let fortress = Fortress.make(
      scenario: scenario, seed: seed, jobs: JobSystem(), isRecording: false)
    // Warm up so the measurement is not dominated by first-touch page faults.
    fortress.run(ticks: 100)

    let host = SimulationHost(fortress: fortress, camera: renderCamera)
    let start = DispatchTime.now().uptimeNanoseconds
    if publishingSnapshots {
      for _ in 0..<ticks { host.stepOnce() }
    } else {
      fortress.run(ticks: ticks)
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    return (Double(elapsed) / Double(ticks) / 1_000_000, fortress)
  }

  let (msPerTick, fortress) = measure(publishingSnapshots: withSnapshot)
  let ticksPerSecond = 1000.0 / msPerTick
  print("scenario      \(scenario.name)")
  print("dwarves       \(scenario.dwarfCount)")
  print("map           \(scenario.mapSize)")
  print("ticks         \(ticks)")
  print(String(format: "ms/tick       %.4f", msPerTick))
  print(String(format: "ticks/sec     %.0f", ticksPerSecond))
  // DF runs 1200 ticks/day at a 100 FPS cap, so 10 ms/tick is the whole frame.
  print(String(format: "%% of 10ms budget  %.1f%%", msPerTick / 10.0 * 100))
  print("materialized blocks \(fortress.map.materializedBlockCount) of \(fortress.map.blockCount)")
  print("tile storage  \(fortress.map.tileStorageBytes / 1024) KiB")

  // Constitution (Quality Gates, v1.1.0): budgets state bytes touched per tick
  // alongside ms/tick. On a unified-memory SoC one controller serves CPU and
  // GPU, so ms/tick measured on one machine hides the ceiling the architecture
  // actually hits -- and unlike a time, this figure is comparable across
  // machines and checkable against a design before the code exists.
  if withSnapshot {
    // `buildSnapshot` draws `depthLayers + 1` layers -- the focused level plus
    // the levels below it. Multiplying by `depthLayers` alone under-reported
    // this by a whole layer (25% at the default 4).
    let layers = max(1, renderCamera.depthLayers + 1)
    let instanceBytes = renderCamera.tileCount * layers * MemoryLayout<TileInstance>.stride
    print("camera        \(renderCamera.size.x)x\(renderCamera.size.y), \(layers) layers")
    print("bytes/tick    \(instanceBytes) (\(instanceBytes / 1024) KiB of instances published)")
    print(
      String(
        format: "bandwidth     %.2f GB/s at %d ticks/s",
        Double(instanceBytes) * Double(SimulationHost.ticksPerSecond) / 1_000_000_000,
        SimulationHost.ticksPerSecond))

    // PC-002 is a statement about the *delta* a window imposes, not about an
    // absolute cost. Gating on a total was gating on a proxy: drift in the
    // baseline silently changed what the threshold meant, and the delta itself
    // only ever got computed by a human reading a comment. Measure both arms
    // here so the gate checks the requirement as written.
    if let snapshotBudget = arguments.string("snapshot-budget-ms").flatMap(Double.init) {
      let baseline = measure(publishingSnapshots: false).msPerTick
      let delta = msPerTick - baseline
      print(String(format: "baseline      %.4f ms/tick (no snapshot)", baseline))
      print(String(format: "snapshot cost %.4f ms/tick (PC-002 budget %.4f)", delta, snapshotBudget))
      if delta > snapshotBudget {
        print(
          String(
            format: "FAIL: snapshot adds %.4f ms/tick, exceeding PC-002's %.4f ms/tick",
            delta, snapshotBudget))
        exit(1)
      }
    }
  }

  if let budget, msPerTick > budget {
    print(String(format: "FAIL: %.4f ms/tick exceeds budget of %.4f ms/tick", msPerTick, budget))
    exit(1)
  }

// MARK: - ui-session

case "ui-session":
  // T014 / SC-004. Drives the real input path -- the same `InputMap` and
  // `HitTest` the window uses -- from a scripted, deterministic gesture list,
  // and records the resulting command stream as a replay fixture.
  //
  // The point is not to test clicking. It is to prove that input reaches the
  // simulation *only* as commands: if a view action ever mutated state, or if
  // hit testing were not a pure function of (click, camera, zoom), the
  // recorded stream would not reproduce the run it came from, and
  // `replay --assert-hashes` would say so.
  let scenario = resolveScenario(arguments.string("scenario", default: "small-dig")!)
  let seed = arguments.uint64("seed", default: 1)
  let ticks = arguments.int("ticks", default: 2000)
  let interval = arguments.int("hash-interval", default: 100)
  guard let output = arguments.string("out") else { fail("ui-session requires --out <path>") }

  let fortress = Fortress.make(scenario: scenario, seed: seed, jobs: JobSystem())
  var controller = CameraController(
    camera: Camera(
      origin: Coord3(0, 0, Int32(scenario.mapSize.z) - 2),
      size: Coord3(40, 24, 1),
      depthLayers: 2),
    pixelsPerTile: 8,
    mapSize: scenario.mapSize)
  let inputMap = InputMap()
  // Driving the real host, not a hand-rolled loop: the fixture is supposed to
  // prove the *windowed* path replays, including the snapshot cache the host
  // owns (SnapshotCache, Tileset.swift).
  let host = SimulationHost(fortress: fortress, camera: controller.camera)

  // A fixed gesture script. Camera moves are interleaved with clicks on
  // purpose: a click's meaning depends on where the camera is, so a bug that
  // let a view action leak into state would change the designations that
  // follow it and break the hashes downstream.
  enum Gesture {
    case key(KeyStroke)
    case click(Click)
  }
  let script: [(tick: Int, gesture: Gesture)] = [
    (100, .click(Click(x: 84.0, y: 84.0))),
    (200, .key(KeyStroke(.right, shift: true))),
    (300, .click(Click(x: 12.5, y: 36.9))),
    (400, .key(KeyStroke(.down))),
    (500, .click(Click(x: 160.0, y: 100.0))),
    (600, .key(KeyStroke(.character("+")))),
    (700, .click(Click(x: 200.0, y: 40.0))),
    (800, .key(KeyStroke(.pageDown))),
    (900, .click(Click(x: 64.0, y: 64.0))),
    (1000, .key(KeyStroke(.left))),
    (1100, .click(Click(x: 100.0, y: 150.0))),
  ]

  var checkpoints: [Replay.Checkpoint] = []
  for tick in 0..<ticks {
    for entry in script where entry.tick == tick {
      let action: InputAction
      switch entry.gesture {
      case .key(let stroke):
        action = inputMap.action(for: stroke)
      case .click(let click):
        action = inputMap.action(
          for: click, camera: controller.camera, pixelsPerTile: controller.pixelsPerTile)
      }
      switch action {
      case .view(let viewAction):
        controller.apply(viewAction)
        host.setCamera(controller.camera)
      case .fortress(let command):
        host.submit(command)
      case .ignored:
        break
      }
    }
    // Publishes a snapshot every tick, as a real window would.
    host.stepOnce()
    if interval > 0, (tick + 1) % interval == 0 {
      checkpoints.append(Replay.Checkpoint(tick: UInt64(tick + 1), hash: host.stateHash))
    }
  }

  let session = Replay(
    seed: seed,
    mapSize: scenario.mapSize,
    tickCount: UInt64(ticks),
    hashInterval: UInt32(interval),
    commands: host.recording,
    checkpoints: checkpoints
  )
  do {
    try session.write(to: output)
  } catch {
    fail("could not write \(output): \(error)")
  }
  print(
    "recorded UI session: \(ticks) ticks, \(session.commands.count) commands, "
      + "\(checkpoints.count) checkpoints -> \(output)")
  print("final hash \(String(host.stateHash, radix: 16))")

// MARK: - shot

case "shot":
  // Constitution V: how an agent looks at the *renderer*. Shares the real
  // drawing path, so what this captures is what a player sees.
  let scenario = resolveScenario(arguments.string("scenario", default: "small-dig")!)
  let seed = arguments.uint64("seed", default: 1)
  let ticks = arguments.int("tick", default: 0)
  let tilesetName = arguments.string("tileset", default: "ascii")!
  let pixelsPerTile = arguments.int("scale", default: 8)
  let output = arguments.string("out", default: "frame.png")!

  guard let tileset = Tileset.named(tilesetName) else {
    fail("unknown tileset '\(tilesetName)'. Available: \(Tileset.all.map(\.name).joined(separator: ", "))")
  }

  let fortress = Fortress.make(scenario: scenario, seed: seed, jobs: JobSystem(), isRecording: false)
  fortress.run(ticks: ticks)

  let z = Int32(arguments.int("z", default: Int(scenario.mapSize.z) - 2))
  let camera = Camera(
    origin: Coord3(Int32(arguments.int("x", default: 0)), Int32(arguments.int("y", default: 0)), z),
    size: Coord3(
      Int32(arguments.int("width", default: Int(scenario.mapSize.x))),
      Int32(arguments.int("height", default: Int(scenario.mapSize.y))),
      1
    ),
    depthLayers: arguments.int("layers", default: 2)
  )
  let snapshot = fortress.snapshot(camera: camera, tileset: tileset)

  do {
    let renderer = try TilemapRenderer()
    let image = try renderer.capture(snapshot, pixelsPerTile: pixelsPerTile)
    try image.writePNG(to: output)
    print("wrote \(output)  \(image.width)x\(image.height)")
    for (key, value) in image.metadata.sorted(by: { $0.key < $1.key }) {
      print("  \(key)  \(value)")
    }
  } catch {
    fail("\(error)")
  }

// MARK: - scenarios

case "scenarios":
  for scenario in Scenario.all {
    print("\(scenario.name)  map=\(scenario.mapSize)  dwarves=\(scenario.dwarfCount)")
  }

// MARK: - help

default:
  print(
    """
    dfsim — headless driver for dwarf-fortress-apple

    VERBS
      ascii              Render a z-level as text after N ticks
                         --scenario --seed --tick --z
      record             Record a replay fixture with hash checkpoints
                         --scenario --seed --ticks --hash-interval --out
      replay <path>      Replay a fixture
                         --assert-hashes --threads
      determinism-check  Run a scenario at several thread counts and compare
                         --scenario --seed --ticks --threads 1,2,3,7,16,64
      bench              Measure ms/tick
                         --scenario --seed --ticks --budget-ms
                         --with-snapshot   also publish a snapshot each tick
                         --width --height --layers   snapshot camera
                         --snapshot-budget-ms   gate PC-002 on the delta
      ui-session         Record a scripted-input session as a replay fixture
                         --scenario --seed --ticks --hash-interval --out
      shot               Render a frame to a PNG, headless
                         --scenario --seed --tick --z --x --y --width --height
                         --layers --tileset --scale --out
      scenarios          List available scenarios

    Determinism is the point. If two of these disagree, trust the failure.
    """
  )
  if arguments.verb != "help" && !arguments.verb.isEmpty {
    fail("unknown verb '\(arguments.verb)'")
  }
}

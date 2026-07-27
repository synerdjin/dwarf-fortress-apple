import DFCore
import DFECS
import DFRender
import DFSim
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
  let threadCounts = arguments.intList("threads", default: [1, 2, 4])

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

  let fortress = Fortress.make(
    scenario: scenario, seed: seed, jobs: JobSystem(), isRecording: false)
  // Warm up so the measurement is not dominated by first-touch page faults.
  fortress.run(ticks: 100)

  let start = DispatchTime.now().uptimeNanoseconds
  fortress.run(ticks: ticks)
  let elapsed = DispatchTime.now().uptimeNanoseconds - start

  let msPerTick = Double(elapsed) / Double(ticks) / 1_000_000
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

  if let budget, msPerTick > budget {
    print(String(format: "FAIL: %.4f ms/tick exceeds budget of %.4f ms/tick", msPerTick, budget))
    exit(1)
  }

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
                         --scenario --seed --ticks --threads 1,2,4
      bench              Measure ms/tick
                         --scenario --seed --ticks --budget-ms
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

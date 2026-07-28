import DFCore
import DFECS
import DFSim
import DFTesting
import Foundation

func registerMapStoreTests() {
  suite("SPEC-M0-MAP: Tile layout") {
    test("Tile is exactly 8 bytes with no interior padding") {
      // Padding bytes are uninitialized and would feed garbage into buffer
      // hashing, producing digests that differ run to run for no reason.
      expectEqual(MemoryLayout<Tile>.size, 8)
      expectEqual(MemoryLayout<Tile>.stride, 8)
      expect(StateHasher.hasNoPadding(Tile.self, fieldByteCount: 8))
    }

    test("Command and TimedCommand have no padding either") {
      // These are bulk-written to replay files; a padding byte would put
      // uninitialized memory on disk and make fixtures irreproducible.
      expect(StateHasher.hasNoPadding(Command.self, fieldByteCount: 32))
      expectEqual(MemoryLayout<Command>.size, 32)
      expectEqual(MemoryLayout<TimedCommand>.size, 40)
    }

    test("Frozen raw values") {
      // These appear in saves and fixtures; renumbering invalidates both.
      expectEqual(TileType.wall.rawValue, 0)
      expectEqual(TileType.floor.rawValue, 1)
      expectEqual(Designation.dig.rawValue, 1)
      expectEqual(CommandKind.designate.rawValue, 1)
      expectEqual(CommandKind.spawnDwarf.rawValue, 3)
    }

    test("Passability") {
      expect(!TileType.wall.isPassable)
      expect(TileType.floor.isPassable)
      expect(TileType.wall.isMineable)
      expect(!TileType.floor.isMineable)
    }
  }

  suite("SPEC-M0-MAP: Block store") {
    test("A fresh map is fully uniform and holds no tile storage") {
      // The whole point of palette compression: an unexcavated fortress costs
      // one header per block and nothing else.
      let map = MapStore(size: Coord3(256, 256, 32))
      expectEqual(map.materializedBlockCount, 0)
      expectEqual(map.tileStorageBytes, 0)
      expectEqual(map[Coord3(100, 100, 10)], Tile.solidGranite)
    }

    test("Blocks are flat 16x16x1 slabs, not cubes") {
      // Matches DF's own geometry -- most systems work within a z-level.
      let map = MapStore(size: Coord3(64, 32, 4))
      expectEqual(MapStore.blockWidth, 16)
      expectEqual(MapStore.blockHeight, 16)
      expectEqual(MapStore.tilesPerBlock, 256)
      // 4 blocks across, 2 down, one per z-level: no vertical grouping.
      expectEqual(map.blockCounts, Coord3(4, 2, 4))
      expectEqual(map.blockCount, 32)
    }

    test("Writing the value a uniform block already holds does not materialize it") {
      // Otherwise painting a designation over solid rock, or any no-op write,
      // would materialize the entire map.
      let map = MapStore(size: Coord3(64, 64, 4))
      map.setTile(Coord3(1, 1, 1), .solidGranite)
      expectEqual(map.materializedBlockCount, 0)
    }

    test("A differing write materializes exactly one block") {
      let map = MapStore(size: Coord3(64, 64, 4))
      map.setTile(Coord3(1, 1, 1), Tile(type: .floor))
      expectEqual(map.materializedBlockCount, 1)
      expectEqual(map[Coord3(1, 1, 1)].type, TileType.floor)
      // Neighbours in the same block keep the old value.
      expectEqual(map[Coord3(2, 1, 1)], Tile.solidGranite)
      // A different block is untouched.
      expectEqual(map[Coord3(40, 40, 1)], Tile.solidGranite)
    }

    test("Reads and writes address the right tile") {
      let map = MapStore(size: Coord3(64, 64, 4))
      for coord in [Coord3(0, 0, 0), Coord3(15, 15, 0), Coord3(16, 16, 1), Coord3(63, 63, 3)] {
        map.setTile(coord, Tile(type: .floor, material: MaterialID(UInt16(coord.x))))
        expectEqual(map[coord].type, TileType.floor, "wrong tile at \(coord)")
        expectEqual(map[coord].material.raw, UInt16(coord.x), "wrong material at \(coord)")
      }
    }

    test("Out-of-bounds reads return wall instead of trapping") {
      // Neighbour scans at the map edge should need no special-casing.
      let map = MapStore(size: Coord3(32, 32, 2))
      expectEqual(map[Coord3(-1, 0, 0)], Tile.solidGranite)
      expectEqual(map[Coord3(0, 0, 99)], Tile.solidGranite)
      expect(!map.contains(Coord3(32, 0, 0)))
    }

    test("A materialized block that becomes uniform collapses back") {
      // Required for hash stability, not just memory: a materialized block of
      // identical tiles and a uniform block holding that tile are the same map.
      let map = MapStore(size: Coord3(32, 32, 1))
      let floor = Tile(type: .floor, material: .soil)
      map.fill(Region3(origin: .zero, size: Coord3(16, 16, 1)), with: floor)
      expectEqual(map.materializedBlockCount, 0, "a fully overwritten block should collapse")
      expectEqual(map[Coord3(5, 5, 0)], floor)
    }

    test("Identical maps hash identically regardless of how they were built") {
      // The history-independence property. One map is filled directly; the
      // other is churned first, materializing and re-collapsing blocks.
      let floor = Tile(type: .floor, material: .soil)

      let direct = MapStore(size: Coord3(64, 64, 2))
      direct.fill(Region3(origin: Coord3(0, 0, 0), size: Coord3(32, 32, 1)), with: floor)

      let churned = MapStore(size: Coord3(64, 64, 2))
      churned.fill(Region3(origin: Coord3(0, 0, 0), size: Coord3(48, 48, 1)), with: floor)
      churned.fill(
        Region3(origin: Coord3(32, 0, 0), size: Coord3(16, 48, 1)),
        with: .solidGranite
      )
      churned.fill(
        Region3(origin: Coord3(0, 32, 0), size: Coord3(48, 16, 1)),
        with: .solidGranite
      )

      expectEqual(direct.stateHash, churned.stateHash, "same map, different history")
    }

    test("Hashing detects a single changed tile") {
      let a = MapStore(size: Coord3(32, 32, 1))
      let b = MapStore(size: Coord3(32, 32, 1))
      expectEqual(a.stateHash, b.stateHash)
      b.setTile(Coord3(7, 7, 0), Tile(type: .floor))
      expectNotEqual(a.stateHash, b.stateHash)
    }

    test("Passability changes bump the block revision, cosmetic ones do not") {
      // Pathfinding invalidates caches off this rather than diffing tiles.
      let map = MapStore(size: Coord3(32, 32, 1))
      let start = map.blockRevision(at: Coord3(1, 1, 0))

      map.modifyTile(Coord3(1, 1, 0)) { $0.designation = .dig }
      expectEqual(
        map.blockRevision(at: Coord3(1, 1, 0)), start,
        "a designation does not change passability")

      map.setTile(Coord3(1, 1, 0), Tile(type: .floor))
      expect(map.blockRevision(at: Coord3(1, 1, 0)) > start, "digging changes passability")
    }

    test("The content revision bumps on any change, not just passability") {
      // Unlike `revision`, a cosmetic-only edit (a designation) must still
      // bump this one -- it exists to invalidate render caches, which care
      // about every visible change, not only passability.
      let map = MapStore(size: Coord3(32, 32, 1))
      let start = map.blockContentRevision(at: Coord3(1, 1, 0))

      map.modifyTile(Coord3(1, 1, 0)) { $0.designation = .dig }
      expect(
        map.blockContentRevision(at: Coord3(1, 1, 0)) > start,
        "a designation is a visible change and must bump the content revision")

      let afterCosmetic = map.blockContentRevision(at: Coord3(1, 1, 0))
      map.setTile(Coord3(1, 1, 0), Tile(type: .floor))
      expect(
        map.blockContentRevision(at: Coord3(1, 1, 0)) > afterCosmetic,
        "a structural change must also bump the content revision")

      // A neighbouring, untouched block must not see its revision move.
      expectEqual(map.blockContentRevision(at: Coord3(20, 20, 0)), 0)
    }

    test("The content revision is not part of the state hash") {
      // It is cache-invalidation bookkeeping, not simulation state (same rule
      // that keeps `Block.revision` and `recording` out of the hash): two maps
      // with identical tiles but different edit histories -- and therefore
      // different content revisions -- must still hash identically.
      let direct = MapStore(size: Coord3(32, 32, 1))
      direct.setTile(Coord3(5, 5, 0), Tile(type: .floor))

      let churned = MapStore(size: Coord3(32, 32, 1))
      // Same end state, reached through several extra revision bumps.
      churned.setTile(Coord3(5, 5, 0), Tile(type: .floor, designation: .dig))
      churned.modifyTile(Coord3(5, 5, 0)) { $0.designation = .none }

      expect(
        churned.blockContentRevision(at: Coord3(5, 5, 0))
          > direct.blockContentRevision(at: Coord3(5, 5, 0)),
        "the churned map should have taken more revisions to reach the same tiles")
      expectEqual(direct.stateHash, churned.stateHash, "different history, same tiles, same hash")
    }

    test("ASCII rendering shows what is there") {
      let map = MapStore(size: Coord3(8, 3, 1))
      map.fill(Region3(origin: Coord3(2, 1, 0), size: Coord3(4, 1, 1)), with: Tile(type: .floor))
      let lines = map.asciiSlice(z: 0).split(separator: "\n").map(String.init)
      expectEqual(lines.count, 3)
      expectEqual(lines[0], "########")
      expectEqual(lines[1], "##....##")
    }
  }

  suite("SPEC-M0-SIM: Replay fixtures") {
    test("A replay round-trips through its binary form byte for byte") {
      // The format is bulk copies of BitwiseCopyable records, so encode/decode
      // cannot drift apart -- but a layout change would break every fixture in
      // the repo silently, so it is asserted.
      let commands = [
        TimedCommand(tick: 0, command: .spawnDwarf(at: Coord3(3, 4, 5))),
        TimedCommand(
          tick: 7,
          command: .designate(
            Region3(origin: Coord3(1, 2, 3), size: Coord3(4, 5, 6)), .dig)),
        TimedCommand(tick: 9, command: .clearDesignation(Region3(corner: .zero, corner: .zero))),
      ]
      let checkpoints = [
        Replay.Checkpoint(tick: 0, hash: 0xDEAD_BEEF),
        Replay.Checkpoint(tick: 100, hash: 0x1234_5678_9ABC_DEF0),
      ]
      let original = Replay(
        seed: 42,
        mapSize: Coord3(64, 48, 8),
        tickCount: 1000,
        hashInterval: 100,
        commands: commands,
        checkpoints: checkpoints
      )

      guard let restored = try? Replay(decoding: original.encoded()) else {
        expect(false, "replay failed to decode")
        return
      }
      expectEqual(restored.seed, original.seed)
      expectEqual(restored.mapSize, original.mapSize)
      expectEqual(restored.tickCount, original.tickCount)
      expectEqual(restored.hashInterval, original.hashInterval)
      expectEqual(restored.commands, original.commands)
      expectEqual(restored.checkpoints, original.checkpoints)
    }

    test("An empty replay round-trips") {
      let empty = Replay(
        seed: 1, mapSize: Coord3(1, 1, 1), tickCount: 0,
        hashInterval: 1, commands: [], checkpoints: []
      )
      guard let restored = try? Replay(decoding: empty.encoded()) else {
        expect(false, "empty replay failed to decode")
        return
      }
      expect(restored.commands.isEmpty)
      expect(restored.checkpoints.isEmpty)
    }

    test("Garbage is rejected rather than misread") {
      var truncated = Replay(
        seed: 1, mapSize: Coord3(8, 8, 1), tickCount: 10,
        hashInterval: 1, commands: [TimedCommand(tick: 0, command: .noopCommand)],
        checkpoints: []
      ).encoded()
      truncated.removeLast(8)

      var threw = false
      do { _ = try Replay(decoding: truncated) } catch { threw = true }
      expect(threw, "a truncated replay must be rejected")

      threw = false
      do { _ = try Replay(decoding: Data([1, 2, 3])) } catch { threw = true }
      expect(threw, "a short file must be rejected")
    }
  }

  suite("SPEC-M0-SIM: Fortress determinism") {
    test("Identical scenarios produce identical hashes") {
      func run() -> UInt64 {
        let fortress = Fortress.make(
          scenario: .smallDig, seed: 7, jobs: JobSystem(), isRecording: false)
        fortress.run(ticks: 500)
        return fortress.stateHash
      }
      expectEqual(run(), run())
    }

    test("Results are independent of partition count") {
      // The M0 acceptance property, asserted in-process as well as by
      // `dfsim determinism-check`.
      var hashes: Set<UInt64> = []
      for partitions in [1, 2, 3, 4, 8] {
        let jobs = JobSystem(
          forceSerial: partitions == 1, partitionCountOverride: partitions)
        let fortress = Fortress.make(
          scenario: .smallDig, seed: 7, jobs: jobs, isRecording: false)
        fortress.run(ticks: 500)
        hashes.insert(fortress.stateHash)
      }
      expectEqual(hashes.count, 1, "partition count changed the result")
    }

    test("Different seeds and different commands produce different states") {
      let jobs = JobSystem()
      let a = Fortress.make(scenario: .smallDig, seed: 1, jobs: jobs, isRecording: false)
      a.run(ticks: 500)
      let b = Fortress.make(scenario: .smallDig, seed: 2, jobs: jobs, isRecording: false)
      b.run(ticks: 500)
      // Same commands, different seed: M0 draws no randomness that affects the
      // outcome yet, so these agree except for the seed in the hash.
      expectNotEqual(a.stateHash, b.stateHash, "the seed is part of state")
    }

    test("Dwarves actually dig: designations become floor") {
      // Behaviour, not just stability. A simulation that deterministically does
      // nothing would pass every other test here.
      let fortress = Fortress.make(
        scenario: .smallDig, seed: 1, jobs: JobSystem(), isRecording: false)
      let target = Coord3(10, 10, fortress.map.size.z - 2)

      fortress.run(ticks: 1)
      expectEqual(fortress.map[target].designation, Designation.dig)
      expectEqual(fortress.map[target].type, TileType.wall)

      fortress.run(ticks: 3000)
      expectEqual(fortress.map[target].type, TileType.floor, "the tile should have been dug")
      expectEqual(fortress.map[target].designation, Designation.none)
    }

    test("An undrained command is part of the state hash") {
      // Two fortresses that have run identically, one holding a command the
      // other does not. They are about to diverge on the next step, so a
      // digest that calls them equal is lying about exactly the property it
      // exists to certify. Before pending commands were hashed, it did.
      let quiet = Fortress.make(
        scenario: .smallDig, seed: 1, jobs: JobSystem(), isRecording: false)
      let loaded = Fortress.make(
        scenario: .smallDig, seed: 1, jobs: JobSystem(), isRecording: false)
      quiet.run(ticks: 300)
      loaded.run(ticks: 300)
      expectEqual(quiet.stateHash, loaded.stateHash, "identical runs must agree first")

      let target = Coord3(4, 4, loaded.map.size.z - 3)
      loaded.submit(
        Command(kind: .designate, region: Region3(origin: target, size: Coord3(1, 1, 1)),
          designation: .dig))
      expectNotEqual(
        quiet.stateHash, loaded.stateHash,
        "a pending command is future-affecting state and must be in the digest")

      // And once it drains and applies, the difference is real map state, so
      // they must still differ -- the pending term is not masking anything.
      loaded.step()
      quiet.step()
      expectNotEqual(quiet.stateHash, loaded.stateHash)
    }

    test("The recording is not part of the state hash") {
      // `recording` exists only while capturing a fixture and is absent while
      // replaying one. If it were hashed, every replay would diverge from the
      // run it replays at the first checkpoint.
      let recording = Fortress.make(scenario: .smallDig, seed: 1, jobs: JobSystem())
      let silent = Fortress.make(
        scenario: .smallDig, seed: 1, jobs: JobSystem(), isRecording: false)
      recording.run(ticks: 400)
      silent.run(ticks: 400)
      expect(!recording.commands.recording.isEmpty, "the recording side must have recorded")
      expect(silent.commands.recording.isEmpty)
      expectEqual(recording.stateHash, silent.stateHash)
    }

    test("Commands are recorded in submission order") {
      let fortress = Fortress.make(scenario: .smallDig, seed: 1, jobs: JobSystem())
      fortress.run(ticks: 2)
      let recorded = fortress.commands.recording
      expectEqual(recorded.count, 5, "4 spawns plus 1 designation")
      expect(recorded.allSatisfy { $0.tick == 0 })
      expectEqual(recorded.first?.command.kind, CommandKind.spawnDwarf)
      expectEqual(recorded.last?.command.kind, CommandKind.designate)
    }
  }
}

extension Command {
  fileprivate static var noopCommand: Command { Command(kind: .noop) }
}

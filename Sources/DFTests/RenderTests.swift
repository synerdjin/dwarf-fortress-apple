import DFCore
import DFECS
import DFRender
import DFSim
import DFTesting
import Metal

func registerRenderTests() {
  suite("SPEC-M1-VIEW: Snapshot boundary") {
    test("TileInstance is 12 bytes with no interior padding") {
      // Uploaded to the GPU by bulk copy; a compiler-inserted hole would put
      // uninitialized bytes in a buffer the shader reads and make captures
      // differ run to run.
      expectEqual(MemoryLayout<TileInstance>.size, 12)
      expectEqual(MemoryLayout<TileInstance>.stride, 12)
      expect(StateHasher.hasNoPadding(TileInstance.self, fieldByteCount: 12))
      expect(StateHasher.hasNoPadding(RGBA8.self, fieldByteCount: 4))
    }

    test("A snapshot covers every visible tile on every layer") {
      let fortress = Fortress.make(
        scenario: .smallDig, seed: 1, jobs: JobSystem(), isRecording: false)
      fortress.run(ticks: 100)
      let camera = Camera(origin: Coord3(0, 0, 6), size: Coord3(20, 10, 1), depthLayers: 2)
      let snapshot = fortress.snapshot(camera: camera)

      expectEqual(snapshot.layerCount, 3, "focused layer plus two below")
      expectEqual(snapshot.instances.count, 20 * 10 * 3)
      expectEqual(snapshot.tick, 100)
      expectEqual(snapshot.stateHash, fortress.stateHash)
    }

    test("DR-001: building a snapshot does not alter simulation state") {
      // The single most important property of the renderer. If this fails,
      // opening a window changes the fortress.
      let fortress = Fortress.make(
        scenario: .smallDig, seed: 1, jobs: JobSystem(), isRecording: false)
      fortress.run(ticks: 200)
      let before = fortress.stateHash

      let camera = Camera(origin: Coord3(0, 0, 6), size: Coord3(64, 40, 1), depthLayers: 3)
      for _ in 0..<20 { _ = fortress.snapshot(camera: camera, tileset: .earth) }

      expectEqual(fortress.stateHash, before, "snapshotting perturbed the simulation")
    }

    test("DR-001: a rendered run and a headless run agree exactly") {
      func run(snapshotting: Bool) -> UInt64 {
        let fortress = Fortress.make(
          scenario: .smallDig, seed: 3, jobs: JobSystem(), isRecording: false)
        let camera = Camera(origin: Coord3(0, 0, 6), size: Coord3(32, 16, 1))
        for _ in 0..<300 {
          fortress.step()
          if snapshotting { _ = fortress.snapshot(camera: camera) }
        }
        return fortress.stateHash
      }
      expectEqual(run(snapshotting: true), run(snapshotting: false))
    }

    test("Snapshots are reproducible for the same state") {
      let fortress = Fortress.make(
        scenario: .smallDig, seed: 1, jobs: JobSystem(), isRecording: false)
      fortress.run(ticks: 500)
      let camera = Camera(origin: Coord3(0, 0, 6), size: Coord3(30, 20, 1), depthLayers: 2)
      expectEqual(
        fortress.snapshot(camera: camera).instances,
        fortress.snapshot(camera: camera).instances
      )
    }

    test("Off-map regions render as blank rather than failing") {
      let fortress = Fortress.make(
        scenario: .smallDig, seed: 1, jobs: JobSystem(), isRecording: false)
      let camera = Camera(origin: Coord3(-10, -10, 6), size: Coord3(8, 8, 1), depthLayers: 0)
      let snapshot = fortress.snapshot(camera: camera)
      expectEqual(snapshot.instances.count, 64)
      expect(snapshot.instances.allSatisfy { $0.glyph == Glyph.blank.rawValue })
    }

    test("Depth dimming darkens lower layers, in integers") {
      let bright = RGBA8(200, 100, 50)
      let dim = bright.dimmed(numerator: 3, denominator: 5)
      expectEqual(dim.r, 120)
      expectEqual(dim.g, 60)
      expectEqual(dim.b, 30)
      expectEqual(dim.a, 255, "alpha is preserved")
      // Integer arithmetic, so this is exact everywhere rather than
      // approximately equal on most machines.
      expectEqual(bright.dimmed(numerator: 0, denominator: 5), RGBA8(0, 0, 0))
    }

    test("The ring hands back the newest published snapshot") {
      let ring = FrameSnapshotRing()
      expect(ring.latest() == nil, "nothing published yet")

      for tick in 1...5 {
        ring.publish { snapshot in
          snapshot.tick = UInt64(tick)
          snapshot.instances = [TileInstance(glyph: UInt16(tick))]
          snapshot.layerCount = 1
        }
        expectEqual(ring.latest()?.tick, UInt64(tick))
        expectEqual(ring.latest()?.instances.first?.glyph, UInt16(tick))
      }
    }

    test("The ring never hands back a half-written buffer") {
      // A reader must see either the old snapshot or the new one, never a mix.
      // Each published snapshot is internally consistent: every instance
      // carries the same glyph as the tick.
      let ring = FrameSnapshotRing()
      ring.publish { snapshot in
        snapshot.instances = Array(repeating: TileInstance(glyph: 0), count: 4096)
        snapshot.tick = 0
        snapshot.layerCount = 1
      }

      let writer = Thread {
        for tick in 1...200 {
          ring.publish { snapshot in
            snapshot.tick = UInt64(tick)
            snapshot.instances = Array(
              repeating: TileInstance(glyph: UInt16(tick % 1000)), count: 4096)
            snapshot.layerCount = 1
          }
        }
      }
      writer.start()

      var torn = 0
      for _ in 0..<2000 {
        guard let snapshot = ring.latest(), let first = snapshot.instances.first else { continue }
        if !snapshot.instances.allSatisfy({ $0.glyph == first.glyph }) { torn += 1 }
      }
      while !writer.isFinished { usleep(200) }
      expectEqual(torn, 0, "reader observed a partially written snapshot")
    }
  }

  suite("SPEC-M1-VIEW: Glyph atlas and tileset") {
    test("Every glyph is drawn and the atlas is stable") {
      guard let device = MTLCreateSystemDefaultDeviceOrNil() else {
        skip("no Metal device on this machine")
        return
      }
      guard let atlas = try? GlyphAtlas(device: device) else {
        expect(false, "atlas construction failed")
        return
      }
      expectEqual(atlas.glyphCount, Glyph.count)
      expectEqual(atlas.glyphSize, 8)
      // Pinned: if the font changes every golden image changes, and this says
      // so directly instead of leaving a pile of image diffs to interpret.
      expectEqual(atlas.contentHash, 1_886_938_064_861_142_108)
    }

    test("Tilesets are distinguishable and total") {
      // Every tile produces exactly one instance; no lookup can fail at draw
      // time, so there is no such thing as an unrenderable tile.
      let tiles = [
        Tile.solidGranite,
        Tile(type: .floor, material: .soil),
        Tile(type: .open, material: .air),
        Tile(type: .wall, designation: .dig),
        Tile(type: .floor, liquid: 5),
      ]
      for tile in tiles {
        let ascii = Tileset.ascii.instance(for: tile, depth: 0)
        let earth = Tileset.earth.instance(for: tile, depth: 0)
        expectEqual(ascii.glyph, earth.glyph, "tilesets agree on glyph, differ on colour")
      }
      // The palettes must actually differ, or FR-007 is cosmetic.
      expectNotEqual(
        Tileset.ascii.instance(for: .solidGranite, depth: 0).foreground,
        Tileset.earth.instance(for: .solidGranite, depth: 0).foreground
      )
    }

    test("Designations and liquid take precedence over bare terrain") {
      let designated = Tile(type: .wall, designation: .dig)
      expectEqual(
        Tileset.ascii.instance(for: designated, depth: 0).glyph,
        Glyph.designation.rawValue)

      let flooded = Tile(type: .floor, liquid: 6)
      expectEqual(
        Tileset.ascii.instance(for: flooded, depth: 0).glyph,
        Glyph.deepLiquid.rawValue)
    }
  }

  suite("SPEC-M1-VIEW: Headless capture") {
    test("SC-003: two captures of the same state are byte-identical") {
      guard let renderer = makeRendererOrSkip() else { return }
      let fortress = Fortress.make(
        scenario: .smallDig, seed: 1, jobs: JobSystem(), isRecording: false)
      fortress.run(ticks: 600)
      let camera = Camera(origin: Coord3(0, 0, 6), size: Coord3(32, 16, 1), depthLayers: 1)
      let snapshot = fortress.snapshot(camera: camera)

      let first: CapturedImage
      let second: CapturedImage
      do {
        first = try renderer.capture(snapshot, pixelsPerTile: 8)
        second = try renderer.capture(snapshot, pixelsPerTile: 8)
      } catch {
        expect(false, "capture failed: \(error)")
        return
      }
      expectEqual(first.pixelHash, second.pixelHash)
      expect(first.bgra == second.bgra, "captures differed byte for byte")
      expectEqual(first.width, 256)
      expectEqual(first.height, 128)
    }

    test("SPEC-M1-VIEW: every in-flight instance buffer renders identically") {
      // The renderer rotates through `maxFramesInFlight` instance buffers so a
      // display-link loop cannot overwrite instances the GPU is still reading.
      // Rotation is only correct if every slot is sized and filled the same
      // way: a slot that never grew, or that kept a stale buffer, would draw a
      // different frame from the same snapshot. Capturing one full cycle plus
      // one wraparound puts every slot on the hook.
      guard let renderer = makeRendererOrSkip() else { return }
      let fortress = Fortress.make(
        scenario: .smallDig, seed: 1, jobs: JobSystem(), isRecording: false)
      fortress.run(ticks: 600)
      let camera = Camera(origin: Coord3(0, 0, 6), size: Coord3(32, 16, 1), depthLayers: 1)
      let snapshot = fortress.snapshot(camera: camera)

      var hashes: [UInt64] = []
      for _ in 0...TilemapRenderer.maxFramesInFlight {
        do {
          hashes.append(try renderer.capture(snapshot, pixelsPerTile: 8).pixelHash)
        } catch {
          expect(false, "capture failed: \(error)")
          return
        }
      }
      expectEqual(hashes.count, TilemapRenderer.maxFramesInFlight + 1)
      expect(
        hashes.allSatisfy { $0 == hashes[0] },
        "instance buffer slots disagreed about the same snapshot: \(hashes)"
      )
    }

    test("SC-002: the capture agrees with the ASCII dump about what is dug") {
      // The requirement that keeps `shot` honest. If the GPU path and the text
      // path disagree about which tiles are floor, one of them is lying and an
      // agent cannot trust either.
      guard let renderer = makeRendererOrSkip() else { return }
      let fortress = Fortress.make(
        scenario: .smallDig, seed: 1, jobs: JobSystem(), isRecording: false)
      fortress.run(ticks: 4000)

      let z: Int32 = 6
      let width: Int32 = 40
      let height: Int32 = 24
      let camera = Camera(
        origin: Coord3(0, 0, z), size: Coord3(width, height, 1), depthLayers: 0)
      let image: CapturedImage
      do {
        image = try renderer.capture(fortress.snapshot(camera: camera), pixelsPerTile: 8)
      } catch {
        expect(false, "capture failed: \(error)")
        return
      }

      let grid = image.coverageGrid(pixelsPerTile: 8)
      let asciiLines = fortress.map.asciiSlice(
        z: z, region: Region3(origin: Coord3(0, 0, z), size: Coord3(width, height, 1))
      ).split(separator: "\n", omittingEmptySubsequences: false).map(Array.init)

      var compared = 0
      var disagreements = 0
      for row in 0..<Int(height) where row < asciiLines.count {
        for column in 0..<Int(width) where column < asciiLines[row].count {
          let glyph = asciiLines[row][column]
          // Open air is the one glyph that renders as nothing at all; every
          // other glyph must put light on the screen.
          let expectLit = glyph != " "
          compared += 1
          if grid[row][column] != expectLit { disagreements += 1 }
        }
      }
      expect(compared > 500, "not enough tiles compared to be meaningful")
      expectEqual(disagreements, 0, "GPU and ASCII disagree on \(disagreements) tiles")
    }

    test("A zero-sized capture is refused, not attempted") {
      guard let renderer = makeRendererOrSkip() else { return }
      let empty = FrameSnapshot(
        instances: [], camera: Camera(size: Coord3(0, 0, 1)), tick: 0, stateHash: 0)
      var threw = false
      do { _ = try renderer.capture(empty) } catch { threw = true }
      expect(threw)
    }
  }
}

/// `MTLCreateSystemDefaultDevice` is unavailable on machines with no GPU; tests
/// that need one skip rather than fail, so the suite still runs in a headless CI
/// that lacks Metal entirely.
func MTLCreateSystemDefaultDeviceOrNil() -> MTLDevice? {
  MTLCreateSystemDefaultDevice()
}

/// Builds a renderer, distinguishing "this machine has no GPU" from "the
/// renderer is broken".
///
/// These call sites used `try? TilemapRenderer()`, which conflated the two:
/// a shader that stopped compiling, a pipeline that could not be created, a
/// texture allocation that failed -- every one of them read as "no GPU
/// available", and the test then reported a pass. `RenderError.noDevice` is
/// the only environmental case. Everything else is precisely the defect these
/// tests exist to catch, so it fails, loudly, with the error attached.
func makeRendererOrSkip() -> TilemapRenderer? {
  do {
    return try TilemapRenderer()
  } catch RenderError.noDevice {
    skip("no Metal device on this machine")
    return nil
  } catch {
    expect(false, "TilemapRenderer init failed, and not for want of a GPU: \(error)")
    return nil
  }
}

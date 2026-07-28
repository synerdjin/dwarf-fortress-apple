import DFCore
import DFECS
import DFSim
import DFTesting
import DFUI

public func registerUITests() {
  suite("SPEC-M1-VIEW: Hit testing (T013)") {
    // The float -> tile boundary. If this is wrong, a click designates the
    // wrong tile, and because the command is integral by then the mistake is
    // invisible downstream -- the replay reproduces the wrong dig perfectly.
    let camera = Camera(origin: Coord3(0, 0, 5), size: Coord3(40, 24, 1), depthLayers: 1)

    test("every fractional position inside a tile yields the identical command") {
      // The requirement tasks.md states verbatim. Sweeping the interior of one
      // tile at sub-pixel resolution is the only way to show the conversion is
      // a floor and not, say, a round -- a round would split the tile down the
      // middle and half these points would land on the neighbour.
      let map = InputMap()
      let pixelsPerTile = 8
      var actions: [InputAction] = []

      // Tile (3, 2) occupies pixels [24, 32) x [16, 24).
      for stepX in 0..<32 {
        for stepY in 0..<32 {
          let x = 24.0 + Double(stepX) * 0.25   // 24.00 ... 31.75
          let y = 16.0 + Double(stepY) * 0.25   // 16.00 ... 23.75
          actions.append(
            map.action(for: Click(x: x, y: y), camera: camera, pixelsPerTile: pixelsPerTile))
        }
      }

      // `InputAction` is Equatable, so compare the values rather than their
      // descriptions -- a stringly-typed set would also pass if two different
      // actions happened to print the same way.
      expectEqual(actions.count, 1024)
      expect(
        actions.allSatisfy { $0 == actions[0] },
        "sub-pixel positions inside one tile produced differing actions")

      // And it is the *right* tile, not merely a consistent one.
      let expected = InputAction.fortress(
        .designate(Region3(origin: Coord3(3, 2, 5), size: Coord3(1, 1, 1)), .dig))
      expectEqual(
        map.action(for: Click(x: 24.0, y: 16.0), camera: camera, pixelsPerTile: 8), expected)
      expectEqual(
        map.action(for: Click(x: 31.99, y: 23.99), camera: camera, pixelsPerTile: 8), expected)
    }

    test("tile boundaries are half-open, so adjacent tiles never overlap") {
      // Exactly on the boundary belongs to the higher tile. Checking this
      // explicitly because an off-by-one here makes one row of pixels
      // designate the tile above it, which no one would notice by looking.
      expectEqual(
        HitTest.tile(at: (x: 15.999, y: 0), camera: camera, pixelsPerTile: 8), Coord3(1, 0, 5))
      expectEqual(
        HitTest.tile(at: (x: 16.0, y: 0), camera: camera, pixelsPerTile: 8), Coord3(2, 0, 5))
    }

    test("the camera origin offsets the hit, so a panned view clicks correctly") {
      let panned = Camera(origin: Coord3(10, 7, 3), size: Coord3(40, 24, 1), depthLayers: 1)
      expectEqual(
        HitTest.tile(at: (x: 0, y: 0), camera: panned, pixelsPerTile: 8), Coord3(10, 7, 3))
      expectEqual(
        HitTest.tile(at: (x: 8, y: 16), camera: panned, pixelsPerTile: 8), Coord3(11, 9, 3))
    }

    test("points outside the grid are rejected rather than clamped") {
      // Negative coordinates are the dangerous case: Int32(-0.5) truncates to
      // 0, so a naive cast turns a click left of the map into a click on
      // column 0. Rejecting before flooring is what prevents that.
      expect(
        HitTest.tile(at: (x: -0.5, y: 4), camera: camera, pixelsPerTile: 8) == nil,
        "a click left of the grid must not resolve to a tile")
      expect(
        HitTest.tile(at: (x: 4, y: -0.5), camera: camera, pixelsPerTile: 8) == nil,
        "a click above the grid must not resolve to a tile")
      expect(
        HitTest.tile(at: (x: 320, y: 4), camera: camera, pixelsPerTile: 8) == nil,
        "a click right of the grid must not resolve to a tile")
      expect(
        HitTest.tile(at: (x: 4, y: 192), camera: camera, pixelsPerTile: 8) == nil,
        "a click below the grid must not resolve to a tile")
      expectEqual(
        InputMap().action(for: Click(x: -1, y: -1), camera: camera, pixelsPerTile: 8), .ignored)
    }

    test("a zero or negative zoom is refused rather than dividing by it") {
      expect(
        HitTest.tile(at: (x: 4, y: 4), camera: camera, pixelsPerTile: 0) == nil,
        "pixelsPerTile of 0 must not be divided by")
    }
  }

  suite("SPEC-M1-VIEW: Camera (T012)") {
    let mapSize = Coord3(48, 48, 16)

    test("pan moves by whole tiles and clamps at the map edge") {
      var controller = CameraController(
        camera: Camera(origin: Coord3(0, 0, 8), size: Coord3(16, 16, 1), depthLayers: 1),
        pixelsPerTile: 8,
        mapSize: mapSize)

      expect(controller.apply(.pan(dx: 5, dy: 3)), "a pan inside the map should report a change")
      expectEqual(controller.camera.origin, Coord3(5, 3, 8))

      // Runs into the edge and stops there rather than going out of bounds.
      controller.apply(.pan(dx: 1000, dy: 1000))
      expectEqual(controller.camera.origin, Coord3(32, 32, 8))
      expect(
        !controller.apply(.pan(dx: 1000, dy: 1000)),
        "panning further at the edge should report no change")
    }

    test("z stays inside the map") {
      var controller = CameraController(
        camera: Camera(origin: Coord3(0, 0, 8), size: Coord3(16, 16, 1), depthLayers: 1),
        pixelsPerTile: 8,
        mapSize: mapSize)
      controller.apply(.changeZ(100))
      expectEqual(controller.camera.origin.z, 15)
      controller.apply(.changeZ(-100))
      expectEqual(controller.camera.origin.z, 0)
    }

    test("zoom doubles and halves within its limits") {
      var controller = CameraController(
        camera: Camera(size: Coord3(16, 16, 1)), pixelsPerTile: 8, mapSize: mapSize)
      controller.apply(.zoom(steps: 1))
      expectEqual(controller.pixelsPerTile, 16)
      controller.apply(.zoom(steps: 5))
      expectEqual(controller.pixelsPerTile, CameraController.maxPixelsPerTile)
      controller.apply(.zoom(steps: -10))
      expectEqual(controller.pixelsPerTile, CameraController.minPixelsPerTile)
    }

    test("a viewport larger than the map pins the origin at zero") {
      // The edge case that makes the clamp arithmetic go negative if written
      // as a bare subtraction.
      var controller = CameraController(
        camera: Camera(origin: Coord3(5, 5, 0), size: Coord3(200, 200, 1), depthLayers: 1),
        pixelsPerTile: 8,
        mapSize: mapSize)
      expectEqual(controller.camera.origin.x, 0)
      expectEqual(controller.camera.origin.y, 0)
      controller.apply(.pan(dx: 10, dy: 10))
      expectEqual(controller.camera.origin, Coord3(0, 0, 0))
    }

    test("a zero-sized window resizes to one tile, not zero") {
      // The spec lists a window briefly sized to zero mid-resize as something
      // rendering must survive. A zero-tile camera produces an empty snapshot.
      var controller = CameraController(
        camera: Camera(size: Coord3(16, 16, 1)), pixelsPerTile: 8, mapSize: mapSize)
      controller.resize(pixelWidth: 0, pixelHeight: 0)
      expectEqual(controller.camera.size.x, 1)
      expectEqual(controller.camera.size.y, 1)
    }
  }

  suite("SPEC-M1-VIEW: Simulation host (T011)") {
    // The window itself cannot be tested headlessly, so everything the window
    // does *except* AppKit lives in SimulationHost and is tested here. What is
    // left untested by design is NSEvent translation and CAMetalLayer
    // presentation; see docs/known-issues.md.

    func makeHost(camera: Camera) -> SimulationHost {
      let fortress = Fortress.make(
        scenario: .smallDig, seed: 1, jobs: JobSystem(), isRecording: false)
      return SimulationHost(fortress: fortress, camera: camera)
    }

    let camera = Camera(origin: Coord3(0, 0, 6), size: Coord3(16, 16, 1), depthLayers: 1)

    test("DR-001: hosting a fortress for a window does not change what it computes") {
      // The strongest form of "rendering must not alter simulation state":
      // run the same scenario for the same ticks with and without the whole
      // host apparatus -- snapshot publication, camera reads, command inbox --
      // and require the hashes to match exactly.
      let bare = Fortress.make(
        scenario: .smallDig, seed: 1, jobs: JobSystem(), isRecording: false)
      bare.run(ticks: 500)

      let host = makeHost(camera: camera)
      for _ in 0..<500 { host.stepOnce() }

      expectEqual(host.stateHash, bare.stateHash)
    }

    test("a published snapshot tracks the tick that produced it") {
      let host = makeHost(camera: camera)
      for _ in 0..<10 { host.stepOnce() }
      guard let snapshot = host.ring.latest() else {
        expect(false, "the host published nothing after ten ticks")
        return
      }
      expectEqual(snapshot.tick, 10)
      expect(!snapshot.isEmpty, "a snapshot of a real camera should have instances")
    }

    test("a command submitted from the UI thread reaches the simulation") {
      // The path input has to travel: submit() from another thread, drained at
      // the top of a tick, applied through the command queue like any other
      // source. If this broke, clicks would silently do nothing.
      let hostA = makeHost(camera: camera)
      let hostB = makeHost(camera: camera)
      for _ in 0..<50 { hostA.stepOnce() }

      hostB.submit(.designate(Region3(origin: Coord3(4, 4, 6), size: Coord3(1, 1, 1)), .dig))
      for _ in 0..<50 { hostB.stepOnce() }

      expect(
        hostA.stateHash != hostB.stateHash,
        "a designation submitted through the host left no trace in the state hash")
    }

    test("setCamera changes what is snapshotted but not what is simulated") {
      let host = makeHost(camera: camera)
      for _ in 0..<20 { host.stepOnce() }
      let firstOrigin = host.ring.latest()?.camera.origin

      host.setCamera(Camera(origin: Coord3(8, 8, 4), size: Coord3(16, 16, 1), depthLayers: 1))
      host.stepOnce()

      expectEqual(host.ring.latest()?.camera.origin, Coord3(8, 8, 4))
      expect(firstOrigin != host.ring.latest()?.camera.origin, "the camera should have moved")
      // One extra tick advanced the sim, so compare against a bare fortress
      // rather than against hashBefore.
      let reference = Fortress.make(
        scenario: .smallDig, seed: 1, jobs: JobSystem(), isRecording: false)
      reference.run(ticks: 21)
      expectEqual(host.stateHash, reference.stateHash)
    }

    test("stop() halts the loop rather than leaving the thread spinning") {
      let host = makeHost(camera: camera)
      expect(host.stepOnce(), "a fresh host should step")
      host.stop()
      expect(!host.stepOnce(), "after stop() the loop must report that it is done")
    }

    test("the host's cached snapshot matches an uncached rebuild through digging and a pan") {
      // The direct correctness check for `SnapshotCache` (docs/state.md,
      // P1 backlog item 9): if a cached slot ever goes stale, this is where it
      // would show up, since every checkpoint compares against a fresh
      // independent fortress that never caches anything.
      //
      // Checkpoints span the tile designated at tick 1 (SPEC-M0-SIM: "Dwarves
      // actually dig"), digging in progress, and digging complete -- so both
      // kinds of change `contentRevision` must catch (a cosmetic designation
      // and a structural dig) are exercised, not just one. The camera changes
      // partway through to exercise cache invalidation on a pan.
      let checkpoints = [1, 5, 20, 100, 500, 3000]
      let stillCamera = Camera(origin: Coord3(0, 0, 6), size: Coord3(24, 16, 1), depthLayers: 1)
      let pannedCamera = Camera(origin: Coord3(6, 4, 6), size: Coord3(24, 16, 1), depthLayers: 1)
      let panAfter = checkpoints.count / 2

      let host = makeHost(camera: stillCamera)
      var ticksSoFar = 0

      for (index, checkpoint) in checkpoints.enumerated() {
        if index == panAfter { host.setCamera(pannedCamera) }
        while ticksSoFar < checkpoint {
          host.stepOnce()
          ticksSoFar += 1
        }

        guard let published = host.ring.latest() else {
          expect(false, "the host published nothing by tick \(checkpoint)")
          return
        }
        let reference = Fortress.make(
          scenario: .smallDig, seed: 1, jobs: JobSystem(), isRecording: false)
        reference.run(ticks: checkpoint)
        let referenceCamera = index < panAfter ? stillCamera : pannedCamera
        expectEqual(
          published.instances, reference.snapshot(camera: referenceCamera).instances,
          "cached and uncached snapshots diverged at tick \(checkpoint)")
      }
    }
  }

  suite("SPEC-M1-VIEW: Input classification (DR-001)") {
    test("every camera key maps to a view action, never a command") {
      // DR-001 in the form the type system can carry: if a movement key ever
      // produced .fortress, it would enter the command queue, be recorded, and
      // change the state hash. Enumerating the bindings here means adding a
      // key that violates it fails a test rather than a replay six weeks on.
      let map = InputMap()
      let movement: [KeyStroke] = [
        KeyStroke(.left), KeyStroke(.right), KeyStroke(.up), KeyStroke(.down),
        KeyStroke(.left, shift: true), KeyStroke(.pageUp), KeyStroke(.pageDown),
        KeyStroke(.character("<")), KeyStroke(.character(">")),
        KeyStroke(.character("+")), KeyStroke(.character("-")),
        KeyStroke(.character("[")), KeyStroke(.character("]")),
      ]
      for stroke in movement {
        switch map.action(for: stroke) {
        case .view: continue
        case .fortress:
          expect(false, "\(stroke) produced a Command; camera keys must be view-only")
        case .ignored:
          expect(false, "\(stroke) is listed as a camera binding but resolves to nothing")
        }
      }
    }

    test("an unbound key is ignored, not guessed at") {
      expectEqual(InputMap().action(for: KeyStroke(.character("q"))), .ignored)
    }

    test("shift pans further than a bare arrow") {
      let map = InputMap()
      expectEqual(map.action(for: KeyStroke(.left)), .view(.pan(dx: -1, dy: 0)))
      expectEqual(
        map.action(for: KeyStroke(.left, shift: true)),
        .view(.pan(dx: -InputMap.fastPanStep, dy: 0)))
    }

    test("DR-001: driving the camera over a live fortress leaves the hash untouched") {
      // The requirement stated end to end rather than by inspection: run a
      // fortress, hash it, drive every camera binding across it, hash again.
      // A view action that quietly reached simulation state would move it.
      let fortress = Fortress.make(
        scenario: .smallDig, seed: 1, jobs: JobSystem(), isRecording: false)
      fortress.run(ticks: 400)
      let before = fortress.stateHash

      var controller = CameraController(
        camera: Camera(origin: Coord3(0, 0, 6), size: Coord3(16, 16, 1), depthLayers: 1),
        pixelsPerTile: 8,
        mapSize: fortress.map.size)
      let map = InputMap()
      for stroke in [
        KeyStroke(.right), KeyStroke(.down), KeyStroke(.right, shift: true),
        KeyStroke(.pageUp), KeyStroke(.pageDown), KeyStroke(.character("+")),
        KeyStroke(.character("-")), KeyStroke(.character("]")), KeyStroke(.character("[")),
      ] {
        if case .view(let action) = map.action(for: stroke) {
          controller.apply(action)
          // Snapshotting is what a real frame does; it must not perturb either.
          _ = fortress.snapshot(camera: controller.camera)
        }
      }

      expectEqual(fortress.stateHash, before)
    }
  }
}

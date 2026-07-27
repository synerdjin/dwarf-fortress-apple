import DFCore
import DFTesting

func registerCoordTests() {
  suite("SPEC-M0-CORE: Coordinates and regions") {
    test("Arithmetic and layout") {
      expect(Coord3(1, 2, 3) + Coord3(10, 20, 30) == Coord3(11, 22, 33))
      expect(Coord3(1, 2, 3) - Coord3(1, 1, 1) == Coord3(0, 1, 2))
      expect(Coord3(x: 5, y: 6, z: 7) == Coord3(5, 6, 7))
      expect(MemoryLayout<Coord3>.size == 12)
      expect(MemoryLayout<Coord3>.stride == 12)
    }

    test("Chebyshev distance matches diagonal movement cost") {
      // Creatures move diagonally at the same cost as orthogonally, so this
      // is both the true step count and the admissible A* heuristic.
      expect(Coord3(0, 0, 0).chebyshevDistance(to: Coord3(3, 3, 0)) == 3)
      expect(Coord3(0, 0, 0).chebyshevDistance(to: Coord3(3, 1, 0)) == 3)
      expect(Coord3(0, 0, 0).chebyshevDistance(to: Coord3(-4, 2, 1)) == 4)
      expect(Coord3(5, 5, 5).chebyshevDistance(to: Coord3(5, 5, 5)) == 0)
    }

    test("Manhattan and squared distances") {
      expect(Coord3(0, 0, 0).manhattanDistance(to: Coord3(3, 3, 0)) == 6)
      expect(Coord3(0, 0, 0).squaredDistance(to: Coord3(3, 4, 0)) == 25)
      // Kept integral on purpose: comparisons work identically on squares,
      // and taking the root would require the float invariant 1 forbids.
      expect(Coord3(0, 0, 0).squaredDistance(to: Coord3(1000, 1000, 1000)) == 3_000_000)
    }

    test("Row-major ordering is total and deterministic") {
      let unsorted = [
        Coord3(1, 0, 0), Coord3(0, 0, 1), Coord3(0, 1, 0), Coord3(0, 0, 0),
      ]
      expect(
        unsorted.sorted() == [
          Coord3(0, 0, 0), Coord3(1, 0, 0), Coord3(0, 1, 0), Coord3(0, 0, 1),
        ])
    }

    test("Neighbour offset tables are correct and stably ordered") {
      expect(Coord3.planarNeighbourOffsets.count == 8)
      expect(Coord3.orthogonalNeighbourOffsets.count == 4)
      expect(!Coord3.planarNeighbourOffsets.contains(Coord3.zero))
      // Order is part of the contract: pathfinding tie-breaks by neighbour
      // index, so reordering this table silently changes chosen routes.
      expect(Coord3.planarNeighbourOffsets.first == Coord3(-1, -1, 0))
      expect(Coord3.orthogonalNeighbourOffsets.first == Coord3(0, -1, 0))
      for offset in Coord3.orthogonalNeighbourOffsets {
        expect(Coord3.planarNeighbourOffsets.contains(offset))
      }
    }

    test("Corner construction normalises drag order") {
      // The UI hands us corners in whatever order the player dragged.
      let forward = Region3(corner: Coord3(1, 2, 3), corner: Coord3(5, 6, 7))
      let backward = Region3(corner: Coord3(5, 6, 7), corner: Coord3(1, 2, 3))
      let mixed = Region3(corner: Coord3(5, 2, 7), corner: Coord3(1, 6, 3))

      expect(forward == backward)
      expect(forward == mixed)
      expect(forward.origin == Coord3(1, 2, 3))
      expect(forward.size == Coord3(5, 5, 5))
      expect(forward.tileCount == 125)
    }

    test("A single-tile drag selects exactly one tile") {
      let region = Region3(corner: Coord3(4, 4, 4), corner: Coord3(4, 4, 4))
      expect(region.tileCount == 1)
      expect(region.contains(Coord3(4, 4, 4)))
      expect(!region.contains(Coord3(5, 4, 4)))
    }

    test("Containment respects the half-open upper bound") {
      let region = Region3(origin: Coord3(0, 0, 0), size: Coord3(3, 3, 3))
      expect(region.contains(Coord3(0, 0, 0)))
      expect(region.contains(Coord3(2, 2, 2)))
      expect(!region.contains(Coord3(3, 0, 0)))
      expect(!region.contains(Coord3(-1, 0, 0)))
      expect(region.end == Coord3(3, 3, 3))
    }

    test("Empty regions contain nothing") {
      let flat = Region3(origin: Coord3(0, 0, 0), size: Coord3(3, 0, 3))
      expect(flat.isEmpty)
      expect(flat.tileCount == 0)
      expect(!flat.contains(Coord3(0, 0, 0)))

      var visited = 0
      flat.forEach { _ in visited += 1 }
      expect(visited == 0)
    }

    test("Intersection") {
      let a = Region3(origin: Coord3(0, 0, 0), size: Coord3(4, 4, 4))
      let b = Region3(origin: Coord3(2, 2, 2), size: Coord3(4, 4, 4))
      let c = Region3(origin: Coord3(4, 0, 0), size: Coord3(4, 4, 4))

      expect(a.intersects(b))
      expect(b.intersects(a))
      // Touching faces do not intersect, because the upper bound is exclusive.
      expect(!a.intersects(c))
    }

    test("Clamping to bounds, including the disjoint case") {
      let bounds = Region3(origin: Coord3(0, 0, 0), size: Coord3(10, 10, 10))
      let overhanging = Region3(origin: Coord3(-5, 5, 5), size: Coord3(20, 20, 20))
      let clamped = overhanging.clamped(to: bounds)
      expect(clamped.origin == Coord3(0, 5, 5))
      expect(clamped.end == Coord3(10, 10, 10))

      // A region entirely outside must clamp to empty, not to a negative size
      // that would make tileCount nonsense.
      let outside = Region3(origin: Coord3(100, 100, 100), size: Coord3(5, 5, 5))
      expect(outside.clamped(to: bounds).isEmpty)
      expect(outside.clamped(to: bounds).tileCount == 0)
    }

    test("Iteration is row-major and complete") {
      // Designation application walks a region and emits one command per
      // tile; the order is part of the replay contract.
      let region = Region3(origin: Coord3(0, 0, 0), size: Coord3(2, 2, 2))
      var visited: [Coord3] = []
      region.forEach { visited.append($0) }

      expect(visited.count == 8)
      expect(
        visited == [
          Coord3(0, 0, 0), Coord3(1, 0, 0), Coord3(0, 1, 0), Coord3(1, 1, 0),
          Coord3(0, 0, 1), Coord3(1, 0, 1), Coord3(0, 1, 1), Coord3(1, 1, 1),
        ])
    }
  }
}

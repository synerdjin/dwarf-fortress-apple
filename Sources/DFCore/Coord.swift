/// A tile coordinate in fortress space.
///
/// `z` increases upward, matching how players talk about the map ("dig down to
/// z-40"). Coordinates are `Int32` rather than `Int` so that packing a coord
/// into a component costs 12 bytes, not 24 -- at a million tile-referencing
/// entities that difference is real.
public struct Coord3: Hashable, Sendable, BitwiseCopyable {
  public var x: Int32
  public var y: Int32
  public var z: Int32

  @inlinable
  public init(_ x: Int32, _ y: Int32, _ z: Int32) {
    self.x = x
    self.y = y
    self.z = z
  }

  @inlinable
  public init(x: Int, y: Int, z: Int) {
    self.init(Int32(x), Int32(y), Int32(z))
  }

  public static let zero = Coord3(0, 0, 0)

  @inlinable
  public static func + (lhs: Coord3, rhs: Coord3) -> Coord3 {
    Coord3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
  }

  @inlinable
  public static func - (lhs: Coord3, rhs: Coord3) -> Coord3 {
    Coord3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
  }

  /// Chebyshev distance: the number of steps for a mover that may travel
  /// diagonally at the same cost as orthogonally. This is the sim's default
  /// notion of distance because it matches how creatures actually move on the
  /// tile grid, and it is the admissible heuristic for A* over that movement.
  @inlinable
  public func chebyshevDistance(to other: Coord3) -> Int32 {
    let dx = abs(x - other.x)
    let dy = abs(y - other.y)
    let dz = abs(z - other.z)
    return Swift.max(dx, dy, dz)
  }

  @inlinable
  public func manhattanDistance(to other: Coord3) -> Int32 {
    abs(x - other.x) + abs(y - other.y) + abs(z - other.z)
  }

  /// Squared euclidean distance, kept as an integer. The square root is never
  /// taken in sim code -- comparisons work identically on the squares, and
  /// taking the root would require a float.
  @inlinable
  public func squaredDistance(to other: Coord3) -> Int64 {
    let dx = Int64(x - other.x)
    let dy = Int64(y - other.y)
    let dz = Int64(z - other.z)
    return dx * dx + dy * dy + dz * dz
  }

  /// The 8 neighbours on the same z-level.
  public static let planarNeighbourOffsets: [Coord3] = [
    Coord3(-1, -1, 0), Coord3(0, -1, 0), Coord3(1, -1, 0),
    Coord3(-1, 0, 0), Coord3(1, 0, 0),
    Coord3(-1, 1, 0), Coord3(0, 1, 0), Coord3(1, 1, 0),
  ]

  /// The 4 orthogonal neighbours on the same z-level, used where diagonal
  /// movement is disallowed (fluid flow, wall adjacency).
  public static let orthogonalNeighbourOffsets: [Coord3] = [
    Coord3(0, -1, 0), Coord3(-1, 0, 0), Coord3(1, 0, 0), Coord3(0, 1, 0),
  ]
}

extension Coord3: CustomStringConvertible {
  public var description: String { "(\(x), \(y), \(z))" }
}

extension Coord3: Comparable {
  /// Row-major ordering (z, then y, then x).
  ///
  /// Sim code sorts by this at phase boundaries to force a deterministic
  /// iteration order where a set or dictionary would otherwise leak hash
  /// ordering into simulation results.
  @inlinable
  public static func < (lhs: Coord3, rhs: Coord3) -> Bool {
    if lhs.z != rhs.z { return lhs.z < rhs.z }
    if lhs.y != rhs.y { return lhs.y < rhs.y }
    return lhs.x < rhs.x
  }
}

/// An axis-aligned box of tiles, half-open on the upper bound.
public struct Region3: Hashable, Sendable, BitwiseCopyable {
  /// Inclusive lower corner.
  public var origin: Coord3
  /// Exclusive extent. A region with any zero component is empty.
  public var size: Coord3

  @inlinable
  public init(origin: Coord3, size: Coord3) {
    self.origin = origin
    self.size = size
  }

  /// Builds the smallest region containing both corners, in either order.
  /// Drag-selection in the UI produces corners in arbitrary order, and this
  /// is where that gets normalised.
  @inlinable
  public init(corner a: Coord3, corner b: Coord3) {
    let lower = Coord3(Swift.min(a.x, b.x), Swift.min(a.y, b.y), Swift.min(a.z, b.z))
    let upper = Coord3(Swift.max(a.x, b.x), Swift.max(a.y, b.y), Swift.max(a.z, b.z))
    self.origin = lower
    self.size = Coord3(upper.x - lower.x + 1, upper.y - lower.y + 1, upper.z - lower.z + 1)
  }

  @inlinable
  public var isEmpty: Bool { size.x <= 0 || size.y <= 0 || size.z <= 0 }

  @inlinable
  public var tileCount: Int {
    isEmpty ? 0 : Int(size.x) * Int(size.y) * Int(size.z)
  }

  /// Exclusive upper corner.
  @inlinable
  public var end: Coord3 { origin + size }

  @inlinable
  public func contains(_ coord: Coord3) -> Bool {
    coord.x >= origin.x && coord.x < origin.x + size.x
      && coord.y >= origin.y && coord.y < origin.y + size.y
      && coord.z >= origin.z && coord.z < origin.z + size.z
  }

  @inlinable
  public func intersects(_ other: Region3) -> Bool {
    !(origin.x >= other.end.x || other.origin.x >= end.x
      || origin.y >= other.end.y || other.origin.y >= end.y
      || origin.z >= other.end.z || other.origin.z >= end.z)
  }

  @inlinable
  public func clamped(to bounds: Region3) -> Region3 {
    let lower = Coord3(
      Swift.max(origin.x, bounds.origin.x),
      Swift.max(origin.y, bounds.origin.y),
      Swift.max(origin.z, bounds.origin.z)
    )
    let upper = Coord3(
      Swift.min(end.x, bounds.end.x),
      Swift.min(end.y, bounds.end.y),
      Swift.min(end.z, bounds.end.z)
    )
    return Region3(
      origin: lower,
      size: Coord3(
        Swift.max(0, upper.x - lower.x),
        Swift.max(0, upper.y - lower.y),
        Swift.max(0, upper.z - lower.z)
      )
    )
  }

  /// Iterates in row-major (z, y, x) order. The order is part of the
  /// contract: designation application walks a region and must produce the
  /// same command sequence on every run.
  @inlinable
  public func forEach(_ body: (Coord3) -> Void) {
    guard !isEmpty else { return }
    for z in origin.z..<end.z {
      for y in origin.y..<end.y {
        for x in origin.x..<end.x {
          body(Coord3(x, y, z))
        }
      }
    }
  }
}

extension Region3: CustomStringConvertible {
  public var description: String { "Region(\(origin) size \(size))" }
}

import DFCore
import DFECS

/// What occupies a tile structurally.
///
/// Raw values are frozen: they appear in saves and replay fixtures.
public enum TileType: UInt8, Sendable, CaseIterable, BitwiseCopyable {
  /// Solid rock or constructed wall. Blocks movement and sight.
  case wall = 0
  /// Walkable surface with support below.
  case floor = 1
  /// Open air. Falls through.
  case open = 2
  /// Walkable slope connecting two z-levels.
  case ramp = 3
  /// Staircase going up only.
  case stairUp = 4
  /// Staircase going down only.
  case stairDown = 5
  /// Staircase connecting both directions.
  case stairUpDown = 6

  /// Whether a creature can occupy this tile.
  @inlinable
  public var isPassable: Bool {
    switch self {
    case .wall: false
    case .floor, .open, .ramp, .stairUp, .stairDown, .stairUpDown: true
    }
  }

  /// Whether this tile can be mined out.
  @inlinable
  public var isMineable: Bool { self == .wall }
}

/// Index into the material table. 0 is reserved for "air / no material".
public struct MaterialID: Hashable, Sendable, BitwiseCopyable {
  public var raw: UInt16

  @inlinable
  public init(_ raw: UInt16) { self.raw = raw }

  public static let air = MaterialID(0)
  /// Placeholder materials until the raws pipeline lands in M4.
  public static let granite = MaterialID(1)
  public static let soil = MaterialID(2)
  public static let water = MaterialID(3)
}

/// Player-issued work markers on a tile.
public enum Designation: UInt8, Sendable, BitwiseCopyable {
  case none = 0
  case dig = 1
  case channel = 2
  case rampUp = 3
  case stairs = 4
}

public struct TileFlags: OptionSet, Sendable, BitwiseCopyable {
  public var rawValue: UInt8

  @inlinable
  public init(rawValue: UInt8) { self.rawValue = rawValue }

  /// Exposed to the sky, per the downward ray rule.
  public static let outside = TileFlags(rawValue: 1 << 0)
  /// Lit. Distinct from `outside`: a lamp-lit cavern is dark-outside.
  public static let light = TileFlags(rawValue: 1 << 1)
  /// Below the surface layer.
  public static let subterranean = TileFlags(rawValue: 1 << 2)
  /// A creature or item currently occupies this tile.
  public static let occupied = TileFlags(rawValue: 1 << 3)
}

/// One map tile.
///
/// Field order is chosen so the struct is exactly 8 bytes with **no interior
/// padding** — padding bytes are uninitialized and would feed garbage into
/// buffer hashing, producing digests that differ run to run for no reason.
/// `SPEC-M0-MAP` asserts the layout.
///
/// Temperature is `UInt16` in whole °U, matching Dwarf Fortress's own
/// representation (0–60000 °U, integers only). Room temperature underground is
/// about 10015 °U and magma about 12000 °U.
public struct Tile: PlainData, Equatable {
  /// What the tile is made of.
  public var material: MaterialID
  /// Temperature, whole °U.
  public var temperature: UInt16
  public var type: TileType
  public var flags: TileFlags
  public var designation: Designation
  /// Liquid depth, 0–7. 7 fills the tile.
  public var liquid: UInt8

  @inlinable
  public init(
    type: TileType = .wall,
    material: MaterialID = .granite,
    temperature: UInt16 = Tile.undergroundAmbient,
    flags: TileFlags = [],
    designation: Designation = .none,
    liquid: UInt8 = 0
  ) {
    self.material = material
    self.temperature = temperature
    self.type = type
    self.flags = flags
    self.designation = designation
    self.liquid = liquid
  }

  /// Ambient underground temperature, whole °U.
  public static let undergroundAmbient: UInt16 = 10015

  /// Solid granite at ambient temperature: what unexcavated rock is.
  public static let solidGranite = Tile(type: .wall, material: .granite)

  /// Empty air.
  public static let openAir = Tile(type: .open, material: .air)

  @inlinable
  public var isPassable: Bool { type.isPassable }

  public func hash(into hasher: inout StateHasher) {
    hasher.combine(material.raw)
    hasher.combine(temperature)
    hasher.combine(type.rawValue)
    hasher.combine(flags.rawValue)
    hasher.combine(designation.rawValue)
    hasher.combine(liquid)
  }

  /// Glyph used by `dfsim ascii`. Rendering only — no sim decision may read it.
  public var glyph: Character {
    if liquid > 0 { return liquid >= 4 ? "≈" : "~" }
    if designation != .none {
      switch designation {
      case .dig: return "▒"
      case .channel: return "▽"
      case .rampUp: return "△"
      case .stairs: return "≡"
      case .none: break
      }
    }
    switch type {
    case .wall: return "#"
    case .floor: return "."
    case .open: return " "
    case .ramp: return "▲"
    case .stairUp: return "<"
    case .stairDown: return ">"
    case .stairUpDown: return "X"
    }
  }
}

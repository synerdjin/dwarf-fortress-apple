import DFCore
import DFECS

/// The glyphs the renderer can draw, in atlas order.
///
/// Deliberately small. M1 needs exactly the glyphs the map uses; a full CP437
/// set arrives when there is a font asset that needs one. Raw values are the
/// atlas indices, so reordering this enum changes every captured image.
public enum Glyph: UInt16, Sendable, CaseIterable, BitwiseCopyable {
  case blank = 0
  case wall = 1
  case floor = 2
  case shallowLiquid = 3
  case deepLiquid = 4
  case designation = 5
  case channelMark = 6
  case rampMark = 7
  case stairsMark = 8
  case ramp = 9
  case stairUp = 10
  case stairDown = 11
  case stairUpDown = 12
  case creature = 13

  public static let count = Glyph.allCases.count
}

/// Maps simulation state to appearance.
///
/// Pure and total: every tile produces exactly one instance, with no lookup
/// that can fail at draw time. Colours are integers so a capture cannot vary
/// with floating-point evaluation.
public struct Tileset: Sendable {
  public let name: String

  public init(name: String) {
    self.name = name
  }

  /// The classic text presentation.
  public static let ascii = Tileset(name: "ascii")
  /// A colour-forward presentation. Same glyphs, different palette — enough to
  /// satisfy FR-007's "switchable without restart" while a real graphical
  /// tileset waits for art.
  public static let earth = Tileset(name: "earth")

  public static let all: [Tileset] = [.ascii, .earth]

  public static func named(_ name: String) -> Tileset? {
    all.first { $0.name == name }
  }

  /// Appearance for one tile.
  public func instance(for tile: Tile, depth: UInt8) -> TileInstance {
    let (glyph, foreground, background) = appearance(of: tile)
    // Integer dimming: each layer down keeps 60% of the previous layer's
    // brightness. Done in integers so the result is identical everywhere.
    var fg = foreground
    var bg = background
    for _ in 0..<depth {
      fg = fg.dimmed(numerator: 3, denominator: 5)
      bg = bg.dimmed(numerator: 3, denominator: 5)
    }
    return TileInstance(glyph: glyph.rawValue, depth: depth, foreground: fg, background: bg)
  }

  /// Appearance for a creature standing on a tile.
  public func creatureInstance(over tile: Tile, depth: UInt8) -> TileInstance {
    var instance = self.instance(for: tile, depth: depth)
    instance.glyph = Glyph.creature.rawValue
    instance.foreground = name == "earth" ? RGBA8(255, 240, 200) : RGBA8(255, 255, 255)
    return instance
  }

  private func appearance(of tile: Tile) -> (Glyph, RGBA8, RGBA8) {
    let earth = name == "earth"

    if tile.liquid > 0 {
      let glyph: Glyph = tile.liquid >= 4 ? .deepLiquid : .shallowLiquid
      return (glyph, RGBA8(90, 160, 230), RGBA8(10, 30, 60))
    }

    if tile.designation != .none {
      let glyph: Glyph =
        switch tile.designation {
        case .dig: .designation
        case .channel: .channelMark
        case .rampUp: .rampMark
        case .stairs: .stairsMark
        case .none: .blank
        }
      return (glyph, RGBA8(220, 190, 90), earth ? RGBA8(40, 32, 24) : RGBA8(0, 0, 0))
    }

    switch tile.type {
    case .wall:
      let stone = earth ? RGBA8(130, 120, 108) : RGBA8(160, 160, 160)
      return (.wall, stone, earth ? RGBA8(28, 24, 20) : RGBA8(0, 0, 0))
    case .floor:
      let dirt =
        tile.material == .soil
        ? (earth ? RGBA8(120, 95, 60) : RGBA8(150, 130, 100))
        : (earth ? RGBA8(100, 96, 90) : RGBA8(128, 128, 128))
      return (.floor, dirt, earth ? RGBA8(18, 15, 12) : RGBA8(0, 0, 0))
    case .open:
      return (.blank, RGBA8(0, 0, 0), earth ? RGBA8(10, 12, 18) : RGBA8(0, 0, 0))
    case .ramp:
      return (.ramp, RGBA8(150, 140, 120), RGBA8(20, 18, 15))
    case .stairUp:
      return (.stairUp, RGBA8(200, 190, 160), RGBA8(20, 18, 15))
    case .stairDown:
      return (.stairDown, RGBA8(200, 190, 160), RGBA8(20, 18, 15))
    case .stairUpDown:
      return (.stairUpDown, RGBA8(220, 210, 180), RGBA8(20, 18, 15))
    }
  }
}

extension Fortress {
  /// Builds a snapshot of the visible region.
  ///
  /// Writes only to `snapshot`; reads only map tiles and positions. Because the
  /// output is indexed by tile position rather than appended, partitioning this
  /// by row range would give disjoint writes and need no merge — which is why
  /// DR-001 holds by construction here rather than by care.
  public func buildSnapshot(
    camera: Camera,
    tileset: Tileset,
    into snapshot: inout FrameSnapshot
  ) {
    let layers = max(1, camera.depthLayers + 1)
    let perLayer = camera.tileCount
    let needed = perLayer * layers
    if snapshot.instances.count != needed {
      snapshot.instances = Array(repeating: TileInstance(), count: needed)
    }

    // Deepest layer first, so the focused level is last and draws on top.
    for layer in 0..<layers {
      let depth = UInt8(layers - 1 - layer)
      let z = camera.origin.z - Int32(depth)
      let base = layer * perLayer

      for row in 0..<Int(camera.size.y) {
        for column in 0..<Int(camera.size.x) {
          let coord = Coord3(
            camera.origin.x + Int32(column),
            camera.origin.y + Int32(row),
            z
          )
          let slot = base + row * Int(camera.size.x) + column
          guard map.contains(coord) else {
            snapshot.instances[slot] = TileInstance()
            continue
          }
          snapshot.instances[slot] = tileset.instance(for: map[coord], depth: depth)
        }
      }
    }

    // Creatures overlay the focused layer only. Where two share a tile the last
    // in dense order wins -- a display artifact, documented, that feeds back
    // into nothing.
    let focusedBase = (layers - 1) * perLayer
    world.storage(Position.self).withDense { values, _ in
      for index in 0..<values.count {
        let coord = values[index].coord
        guard coord.z == camera.origin.z else { continue }
        let column = Int(coord.x - camera.origin.x)
        let row = Int(coord.y - camera.origin.y)
        guard column >= 0, column < Int(camera.size.x), row >= 0, row < Int(camera.size.y)
        else { continue }
        let slot = focusedBase + row * Int(camera.size.x) + column
        snapshot.instances[slot] = tileset.creatureInstance(over: map[coord], depth: 0)
      }
    }

    snapshot.camera = camera
    snapshot.tick = tick
    snapshot.stateHash = stateHash
    snapshot.layerCount = layers
  }

  /// Convenience for callers that want a fresh snapshot rather than reusing one.
  public func snapshot(camera: Camera, tileset: Tileset = .ascii) -> FrameSnapshot {
    var result = FrameSnapshot()
    buildSnapshot(camera: camera, tileset: tileset, into: &result)
    return result
  }
}

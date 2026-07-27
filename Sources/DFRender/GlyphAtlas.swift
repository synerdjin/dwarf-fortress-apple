import DFSim
import Foundation
import Metal

/// The glyph bitmaps, authored for this project.
///
/// **Licensing (FR-013).** These are drawn by hand as part of this repository
/// and carry the project's own licence. Nothing here derives from Dwarf
/// Fortress's tileset or from any third-party font, which sidesteps the
/// redistribution question entirely rather than answering it.
///
/// Chosen over rasterizing a system font because SC-003 requires captures to be
/// byte-identical across runs and machines: an OS text stack offers no such
/// guarantee across versions, and Apple's system fonts are not redistributable
/// anyway. Chosen over bundling a third-party bitmap font because a hand-drawn
/// set of fourteen glyphs is smaller than the licence audit would be.
///
/// A fuller CP437 set can replace this when a milestone needs one; the atlas
/// builder does not care where the bitmaps come from.
enum GlyphFont {
  /// Pixels per glyph edge.
  static let size = 8

  /// One row of eight pixels per string, `#` set and anything else clear.
  /// Written as art so a mistake is visible on inspection.
  static let art: [Glyph: [String]] = [
    .blank: [
      "........",
      "........",
      "........",
      "........",
      "........",
      "........",
      "........",
      "........",
    ],
    // Solid rock: dense hatch, reads as "not passable" at a glance.
    .wall: [
      "########",
      "#.#.#.#.",
      "########",
      ".#.#.#.#",
      "########",
      "#.#.#.#.",
      "########",
      ".#.#.#.#",
    ],
    // Open floor: a single centred dot, like the classic period.
    .floor: [
      "........",
      "........",
      "........",
      "...##...",
      "...##...",
      "........",
      "........",
      "........",
    ],
    .shallowLiquid: [
      "........",
      "........",
      ".##...#.",
      "#..#.#..",
      "....#...",
      "........",
      "........",
      "........",
    ],
    .deepLiquid: [
      "........",
      ".##...#.",
      "#..#.#..",
      "....#...",
      ".##...#.",
      "#..#.#..",
      "....#...",
      "........",
    ],
    // Dig designation: checkerboard, clearly "marked but not yet done".
    .designation: [
      "#.#.#.#.",
      ".#.#.#.#",
      "#.#.#.#.",
      ".#.#.#.#",
      "#.#.#.#.",
      ".#.#.#.#",
      "#.#.#.#.",
      ".#.#.#.#",
    ],
    .channelMark: [
      "########",
      ".######.",
      "..####..",
      "...##...",
      "........",
      "........",
      "........",
      "........",
    ],
    .rampMark: [
      "........",
      "........",
      "........",
      "...##...",
      "..####..",
      ".######.",
      "########",
      "........",
    ],
    .stairsMark: [
      "........",
      "########",
      "........",
      "########",
      "........",
      "########",
      "........",
      "........",
    ],
    .ramp: [
      "........",
      "...##...",
      "..####..",
      "..####..",
      ".######.",
      ".######.",
      "########",
      "........",
    ],
    .stairUp: [
      "........",
      "......##",
      "....##..",
      "..##....",
      "..##....",
      "....##..",
      "......##",
      "........",
    ],
    .stairDown: [
      "........",
      "##......",
      "..##....",
      "....##..",
      "....##..",
      "..##....",
      "##......",
      "........",
    ],
    .stairUpDown: [
      "........",
      "##....##",
      "..##.##.",
      "...###..",
      "...###..",
      "..##.##.",
      "##....##",
      "........",
    ],
    // Creature: a small figure. Round head, shoulders, legs.
    .creature: [
      "..####..",
      ".#....#.",
      ".#.##.#.",
      ".#....#.",
      "..####..",
      "...##...",
      "..#..#..",
      ".#....#.",
    ],
  ]
}

/// A texture holding every glyph, laid out in one row.
///
/// Single-channel coverage: the shader multiplies it against the instance's
/// foreground colour and mixes over the background, so one atlas serves every
/// tileset and recolouring costs nothing.
public final class GlyphAtlas {
  public let texture: MTLTexture
  public let glyphSize: Int
  public let glyphCount: Int

  /// Hash of the atlas bytes. Tests pin it: if the font changes, every golden
  /// image changes with it, and this says so directly instead of leaving a pile
  /// of image diffs to interpret.
  public let contentHash: UInt64

  public init(device: MTLDevice) throws {
    glyphSize = GlyphFont.size
    glyphCount = Glyph.count

    let width = glyphSize * glyphCount
    let height = glyphSize
    var pixels = [UInt8](repeating: 0, count: width * height)

    for glyph in Glyph.allCases {
      guard let art = GlyphFont.art[glyph] else { continue }
      precondition(
        art.count == glyphSize,
        "glyph \(glyph) has \(art.count) rows, expected \(glyphSize)"
      )
      let originX = Int(glyph.rawValue) * glyphSize
      for (row, line) in art.enumerated() {
        let characters = Array(line)
        precondition(
          characters.count == glyphSize,
          "glyph \(glyph) row \(row) has \(characters.count) columns, expected \(glyphSize)"
        )
        for column in 0..<glyphSize where characters[column] == "#" {
          pixels[row * width + originX + column] = 255
        }
      }
    }

    var hasher = FNV()
    for byte in pixels { hasher.combine(byte) }
    contentHash = hasher.value

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r8Unorm,
      width: width,
      height: height,
      mipmapped: false
    )
    descriptor.usage = .shaderRead
    // Managed/private would need a blit; shared lets us write once directly.
    descriptor.storageMode = .shared

    guard let texture = device.makeTexture(descriptor: descriptor) else {
      throw RenderError.textureCreationFailed("glyph atlas")
    }
    texture.replace(
      region: MTLRegionMake2D(0, 0, width, height),
      mipmapLevel: 0,
      withBytes: pixels,
      bytesPerRow: width
    )
    self.texture = texture
  }
}

/// Small FNV-1a, local to the renderer so `DFRender` need not import `DFCore`
/// solely to hash a texture.
struct FNV {
  private var accumulator: UInt64 = 0xcbf2_9ce4_8422_2325

  mutating func combine(_ byte: UInt8) {
    accumulator = (accumulator ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
  }

  var value: UInt64 { accumulator }
}

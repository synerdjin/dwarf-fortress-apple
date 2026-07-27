import DFSim
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A rendered frame, with the metadata needed to tie it back to an exact
/// simulation state.
///
/// **Frame metadata is embedded in the PNG rather than drawn as text.** FR-012
/// asks that a captured frame be self-describing; the consumer that requirement
/// exists for is an agent, and a PNG text chunk is machine-readable where
/// rendered pixels are not. It also removes ~40 letter and digit glyphs from
/// the font this milestone would otherwise have to author. On-screen HUD text
/// belongs with the rest of the UI chrome in M2.
public struct CapturedImage: Sendable {
  public let width: Int
  public let height: Int
  /// Raw BGRA8 pixels, row-major from the top.
  public let bgra: [UInt8]
  public let tick: UInt64
  public let stateHash: UInt64
  public let camera: Camera
  /// Recorded so a golden-image mismatch is diagnosable rather than mysterious:
  /// a different GPU or driver is a legitimate reason for pixels to differ.
  public let deviceName: String

  public init(
    width: Int,
    height: Int,
    bgra: [UInt8],
    tick: UInt64,
    stateHash: UInt64,
    camera: Camera,
    deviceName: String
  ) {
    self.width = width
    self.height = height
    self.bgra = bgra
    self.tick = tick
    self.stateHash = stateHash
    self.camera = camera
    self.deviceName = deviceName
  }

  /// Stable digest of the pixel data alone, excluding metadata.
  ///
  /// This is what golden-image tests compare. Metadata is deliberately excluded
  /// so that re-capturing at a different tick with identical pixels — which
  /// should not happen, but would be worth knowing about — is visible.
  public var pixelHash: UInt64 {
    var hasher = FNV()
    for byte in bgra { hasher.combine(byte) }
    return hasher.value
  }

  public var metadata: [String: String] {
    [
      "tick": "\(tick)",
      "stateHash": String(stateHash, radix: 16),
      "camera": "\(camera.origin) size \(camera.size) layers \(camera.depthLayers)",
      "device": deviceName,
      "pixelHash": String(pixelHash, radix: 16),
    ]
  }

  /// Writes a PNG with the frame metadata in tEXt chunks.
  public func writePNG(to path: String) throws {
    // BGRA -> RGBA. Done explicitly rather than via a colour-management path,
    // because colour management would introduce exactly the kind of
    // platform-dependent transform DR-003 cannot tolerate.
    var rgba = [UInt8](repeating: 0, count: bgra.count)
    for pixel in stride(from: 0, to: bgra.count, by: 4) {
      rgba[pixel] = bgra[pixel + 2]
      rgba[pixel + 1] = bgra[pixel + 1]
      rgba[pixel + 2] = bgra[pixel]
      rgba[pixel + 3] = bgra[pixel + 3]
    }

    guard
      let provider = CGDataProvider(data: Data(rgba) as CFData),
      let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    else {
      throw RenderError.encodingFailed("could not build CGImage")
    }

    let url = URL(fileURLWithPath: path) as CFURL
    guard
      let destination = CGImageDestinationCreateWithURL(
        url, UTType.png.identifier as CFString, 1, nil)
    else {
      throw RenderError.encodingFailed("could not create PNG destination at \(path)")
    }

    let pngMetadata: [String: Any] = [
      kCGImagePropertyPNGDescription as String:
        metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        .joined(separator: " "),
    ]
    CGImageDestinationAddImage(
      destination, image,
      [kCGImagePropertyPNGDictionary as String: pngMetadata] as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
      throw RenderError.encodingFailed("could not finalize PNG at \(path)")
    }
  }

  /// Renders the capture back to text, one character per tile, by sampling the
  /// centre pixel of each tile cell.
  ///
  /// This is how SC-002 is checked: the same scene rendered through the GPU and
  /// through `dfsim ascii` must agree about which tiles are floor. Comparing
  /// pixels to glyphs directly would be brittle; comparing *coverage* is not.
  public func coverageGrid(pixelsPerTile: Int) -> [[Bool]] {
    let columns = width / pixelsPerTile
    let rows = height / pixelsPerTile
    var grid = [[Bool]](repeating: [Bool](repeating: false, count: columns), count: rows)
    for row in 0..<rows {
      for column in 0..<columns {
        // Any lit pixel in the cell counts as covered.
        var lit = false
        for y in 0..<pixelsPerTile where !lit {
          for x in 0..<pixelsPerTile {
            let px = ((row * pixelsPerTile + y) * width + column * pixelsPerTile + x) * 4
            if bgra[px] > 24 || bgra[px + 1] > 24 || bgra[px + 2] > 24 {
              lit = true
              break
            }
          }
        }
        grid[row][column] = lit
      }
    }
    return grid
  }
}

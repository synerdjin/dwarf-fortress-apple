import DFCore
import DFSim

/// Converting a pointer position into a tile.
///
/// **This is the only place in the project where a float becomes simulation
/// input.** Constitution I bans floats from simulation state; the pointer
/// arrives as a float because that is what the window server provides, so the
/// conversion has to happen somewhere, and the design decision is to make it
/// happen exactly once, in a free function, with a test on it — rather than
/// inline in a click handler where the next person adds a second one.
///
/// The whole correctness argument is one sentence: every pointer position
/// inside a tile's pixel square must produce that tile and no other, so the
/// command a click generates cannot depend on where in the tile the click
/// landed.
public enum HitTest {
  /// The tile under a point given in view pixels, or `nil` if the point is
  /// outside the drawn grid.
  ///
  /// - Parameters:
  ///   - point: position in view pixels, origin top-left, y increasing
  ///     downward — matching both the capture and the ASCII dump.
  ///   - camera: the camera the frame was drawn with.
  ///   - pixelsPerTile: current zoom.
  public static func tile(
    at point: (x: Double, y: Double),
    camera: Camera,
    pixelsPerTile: Int
  ) -> Coord3? {
    guard pixelsPerTile > 0 else { return nil }

    // A negative coordinate is outside the grid, and must be rejected *before*
    // flooring rather than after. `Int32(-0.5)` truncates toward zero and would
    // silently yield column 0 for a click to the left of the map, so a click
    // outside the window would designate a tile inside it.
    guard point.x >= 0, point.y >= 0 else { return nil }

    // `.rounded(.down)` and not a cast: the cast truncates, and the two agree
    // only for non-negative values. Flooring is the operation actually meant,
    // and stating it survives someone later relaxing the guard above.
    let column = Int((point.x / Double(pixelsPerTile)).rounded(.down))
    let row = Int((point.y / Double(pixelsPerTile)).rounded(.down))

    guard column < Int(camera.size.x), row < Int(camera.size.y) else { return nil }

    // From here on everything is integral. No float reaches the return value.
    return Coord3(
      camera.origin.x + Int32(column),
      camera.origin.y + Int32(row),
      camera.origin.z
    )
  }
}

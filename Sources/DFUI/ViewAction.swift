import DFCore
import DFSim

/// What a piece of input is allowed to do.
///
/// Every event the window receives resolves to exactly one of these, and the
/// distinction is the whole point of the type. Constitution III says simulation
/// state is mutated only by applying `Command` values from the queue, so input
/// handling has to be explicit about which of the two things it is doing:
///
/// - A **view action** changes what the player is looking at. It touches the
///   `Camera` and nothing else. It is never recorded, never replayed, and
///   cannot appear in a state hash (DR-001).
/// - A **fortress action** carries a `Command`. It goes through the queue like
///   every other command, so it replays identically.
///
/// Modelling this as one enum rather than two code paths means a new input
/// binding has to declare which kind it is at the point it is written. There is
/// no third case and no default, so "I'll just poke the world from the click
/// handler" is not expressible.
public enum InputAction: Equatable, Sendable {
  case view(ViewAction)
  case fortress(Command)
  /// Input that resolves to nothing — an unbound key, or a click outside the
  /// map. Explicit rather than optional so callers must handle it.
  case ignored
}

/// A change to what is displayed. Never affects simulation state.
public enum ViewAction: Equatable, Sendable {
  /// Move the camera by whole tiles. Integral so panning cannot drift.
  case pan(dx: Int32, dy: Int32)
  /// Change the focused z-level.
  case changeZ(Int32)
  /// Multiply the zoom level by a step, clamped by `Camera` limits.
  case zoom(steps: Int)
  /// Change how many levels below the focused one are drawn.
  case changeDepthLayers(Int)
}

/// The camera, plus the rules for moving it.
///
/// Split from `DFSim.Camera` deliberately: `Camera` is a plain value the
/// snapshot carries, and this is the mutable, policy-bearing thing the UI owns.
/// Keeping the policy here means the simulation never links against it.
public struct CameraController: Sendable {
  /// Zoom is expressed as pixels per tile, an integer, so a capture at a given
  /// zoom is reproducible. DR-002 permits floats in presentation code, but
  /// there is no reason to introduce one where an integer does the job.
  public static let minPixelsPerTile = 4
  public static let maxPixelsPerTile = 32

  public private(set) var camera: Camera
  public private(set) var pixelsPerTile: Int

  /// Bounds the camera is clamped to. Set from the map extents at startup.
  public var mapSize: Coord3

  public init(
    camera: Camera = Camera(),
    pixelsPerTile: Int = 8,
    mapSize: Coord3
  ) {
    self.camera = camera
    self.pixelsPerTile = pixelsPerTile
    self.mapSize = mapSize
    clamp()
  }

  /// Applies a view action. Returns whether anything actually changed, so the
  /// caller can skip a redraw.
  @discardableResult
  public mutating func apply(_ action: ViewAction) -> Bool {
    let before = camera
    let beforeZoom = pixelsPerTile

    switch action {
    case .pan(let dx, let dy):
      camera.origin.x += dx
      camera.origin.y += dy
    case .changeZ(let delta):
      camera.origin.z += delta
    case .zoom(let steps):
      // Doubling per step keeps the tile grid pixel-aligned at every level,
      // which nearest-neighbour sampling needs to stay crisp.
      var next = pixelsPerTile
      for _ in 0..<abs(steps) {
        next = steps > 0 ? next * 2 : next / 2
      }
      pixelsPerTile = next
    case .changeDepthLayers(let delta):
      camera.depthLayers = max(0, camera.depthLayers + delta)
    }

    clamp()
    return camera != before || pixelsPerTile != beforeZoom
  }

  /// Keeps the camera inside the map and the zoom inside its limits.
  ///
  /// Clamping rather than rejecting: a pan that would run off the edge slides
  /// to the edge and stops, which is what every map interface does and what the
  /// spec's "camera outside the map" edge case asks for.
  private mutating func clamp() {
    pixelsPerTile = min(
      CameraController.maxPixelsPerTile,
      max(CameraController.minPixelsPerTile, pixelsPerTile))

    camera.size.x = max(1, camera.size.x)
    camera.size.y = max(1, camera.size.y)
    camera.size.z = 1

    // The viewport may legitimately be larger than the map; in that case the
    // only valid origin is 0 and max() below would otherwise go negative.
    let maxX = max(0, mapSize.x - camera.size.x)
    let maxY = max(0, mapSize.y - camera.size.y)
    camera.origin.x = min(maxX, max(0, camera.origin.x))
    camera.origin.y = min(maxY, max(0, camera.origin.y))
    camera.origin.z = min(max(0, mapSize.z - 1), max(0, camera.origin.z))
  }

  /// Resizes the viewport to whatever the window can show at the current zoom.
  @discardableResult
  public mutating func resize(pixelWidth: Int, pixelHeight: Int) -> Bool {
    let before = camera
    // A window mid-resize can be zero-sized; the spec lists that as an edge
    // case rendering must survive. One tile is the floor, not zero, because a
    // zero-tile camera makes an empty snapshot and an empty draw.
    camera.size.x = Int32(max(1, pixelWidth / pixelsPerTile))
    camera.size.y = Int32(max(1, pixelHeight / pixelsPerTile))
    clamp()
    return camera != before
  }
}

import DFCore
import DFSim

/// A key press, described without reference to AppKit.
///
/// The window layer translates `NSEvent` into this; everything below is
/// testable in a plain executable, which Constitution V requires. A binding
/// table that can only be exercised by opening a window is a binding table
/// nobody checks.
public struct KeyStroke: Hashable, Sendable {
  public enum Key: Hashable, Sendable {
    case left, right, up, down
    case pageUp, pageDown
    case character(Character)
  }

  public var key: Key
  public var shift: Bool

  public init(_ key: Key, shift: Bool = false) {
    self.key = key
    self.shift = shift
  }
}

/// A mouse click, in view pixels.
public struct Click: Equatable, Sendable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

/// Turns input into `InputAction`s.
///
/// Stateless and pure: the same input with the same camera always yields the
/// same action. That is what lets `ui-session.rec` replay (SC-004) — a recorded
/// session is a command stream, and a command stream is only reproducible if
/// the thing that produced it was a function.
public struct InputMap: Sendable {
  /// How far one arrow-key press pans, in tiles. Shift multiplies it.
  public static let panStep: Int32 = 1
  public static let fastPanStep: Int32 = 10

  public init() {}

  public func action(for stroke: KeyStroke) -> InputAction {
    let step = stroke.shift ? InputMap.fastPanStep : InputMap.panStep

    switch stroke.key {
    case .left: return .view(.pan(dx: -step, dy: 0))
    case .right: return .view(.pan(dx: step, dy: 0))
    case .up: return .view(.pan(dx: 0, dy: -step))
    case .down: return .view(.pan(dx: 0, dy: step))
    case .pageUp: return .view(.changeZ(1))
    case .pageDown: return .view(.changeZ(-1))
    case .character(let character):
      switch character {
      case "<": return .view(.changeZ(1))
      case ">": return .view(.changeZ(-1))
      case "+", "=": return .view(.zoom(steps: 1))
      case "-", "_": return .view(.zoom(steps: -1))
      case "[": return .view(.changeDepthLayers(-1))
      case "]": return .view(.changeDepthLayers(1))
      default: return .ignored
      }
    }
  }

  /// A click designates one tile for digging.
  ///
  /// M1 implements exactly one fortress action on purpose: the milestone's job
  /// is to prove input can reach the simulation through the command queue and
  /// replay identically, not to build the designation UI. That is M2.
  public func action(
    for click: Click,
    camera: Camera,
    pixelsPerTile: Int
  ) -> InputAction {
    guard
      let tile = HitTest.tile(
        at: (x: click.x, y: click.y),
        camera: camera,
        pixelsPerTile: pixelsPerTile)
    else {
      return .ignored
    }
    return .fortress(
      .designate(Region3(origin: tile, size: Coord3(1, 1, 1)), .dig))
  }
}

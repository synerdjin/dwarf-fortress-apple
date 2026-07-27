import DFCore
import DFECS
import Foundation

/// One tile's worth of drawing instructions.
///
/// 12 bytes, no interior padding — this is uploaded to the GPU by bulk copy,
/// and a compiler-inserted hole would put uninitialized bytes in a buffer the
/// shader reads, making captures differ run to run for no reason.
public struct TileInstance: PlainData, Equatable {
  /// Index into the glyph atlas.
  public var glyph: UInt16
  /// Depth-dimming level: 0 is the focused layer, higher is further below.
  public var depth: UInt8
  /// Explicit padding, always zero.
  public var reserved: UInt8
  public var foreground: RGBA8
  public var background: RGBA8

  @inlinable
  public init(
    glyph: UInt16 = 0,
    depth: UInt8 = 0,
    foreground: RGBA8 = .white,
    background: RGBA8 = .black
  ) {
    self.glyph = glyph
    self.depth = depth
    self.reserved = 0
    self.foreground = foreground
    self.background = background
  }

  public func hash(into hasher: inout StateHasher) {
    hasher.combine(glyph)
    hasher.combine(depth)
    hasher.combine(reserved)
    foreground.hash(into: &hasher)
    background.hash(into: &hasher)
  }
}

/// 8-bit-per-channel colour. Presentation only — never enters simulation state.
public struct RGBA8: PlainData, Equatable {
  public var r: UInt8
  public var g: UInt8
  public var b: UInt8
  public var a: UInt8

  @inlinable
  public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
    self.r = r
    self.g = g
    self.b = b
    self.a = a
  }

  public static let black = RGBA8(0, 0, 0)
  public static let white = RGBA8(255, 255, 255)

  /// Scales toward black. Used for depth dimming, computed in integers so the
  /// result cannot vary with floating-point evaluation order.
  @inlinable
  public func dimmed(numerator: UInt32, denominator: UInt32) -> RGBA8 {
    func scale(_ channel: UInt8) -> UInt8 {
      UInt8(UInt32(channel) * numerator / denominator)
    }
    return RGBA8(scale(r), scale(g), scale(b), a)
  }

  public func hash(into hasher: inout StateHasher) {
    hasher.combine(r)
    hasher.combine(g)
    hasher.combine(b)
    hasher.combine(a)
  }
}

/// What part of the world is shown. Presentation state, not simulation state.
///
/// Position is integral so panning cannot accumulate drift; only `zoom` is a
/// float, and it never leaves the renderer.
public struct Camera: Sendable, Equatable {
  /// Top-left visible tile.
  public var origin: Coord3
  /// Visible extent in tiles.
  public var size: Coord3
  /// How many levels below the focused one to draw.
  public var depthLayers: Int

  public init(
    origin: Coord3 = .zero,
    size: Coord3 = Coord3(80, 40, 1),
    depthLayers: Int = 3
  ) {
    self.origin = origin
    self.size = size
    self.depthLayers = depthLayers
  }

  public var tileCount: Int { Int(size.x) * Int(size.y) }
}

/// A complete, self-describing frame's worth of drawing data.
///
/// Produced by the simulation at the end of a tick, consumed by the renderer.
/// The renderer never touches live simulation state, which is what lets the two
/// run at different rates and guarantees rendering cannot perturb a replay.
public struct FrameSnapshot: Sendable {
  /// Instances for every drawn layer, deepest first, each `camera.tileCount`
  /// long. Layer `depthLayers` is the focused level.
  public var instances: [TileInstance]
  public var camera: Camera
  public var tick: UInt64
  /// The simulation state hash at this tick, so a capture can be tied to an
  /// exact simulation state.
  public var stateHash: UInt64
  /// Layers actually present in `instances`.
  public var layerCount: Int

  public init(
    instances: [TileInstance] = [],
    camera: Camera = Camera(),
    tick: UInt64 = 0,
    stateHash: UInt64 = 0,
    layerCount: Int = 1
  ) {
    self.instances = instances
    self.camera = camera
    self.tick = tick
    self.stateHash = stateHash
    self.layerCount = layerCount
  }

  public var isEmpty: Bool { instances.isEmpty }
}

/// Triple-buffered handoff from the simulation thread to the renderer.
///
/// **The data is never locked.** A lock around the snapshot itself would make
/// the simulation's tick time depend on the display's refresh rate, which
/// PC-002 forbids: simulation cost must not change because a window is open.
/// Instead the writer fills whichever buffer the reader is not holding, and a
/// mutex guards only the three index variables — a critical section of a few
/// instructions that neither party can be slow inside. Building a snapshot and
/// reading one both happen entirely outside it.
///
/// With three buffers the writer always has a free one: at most one is
/// published and at most one is being read.
public final class FrameSnapshotRing: @unchecked Sendable {
  /// Rotating scratch buffers, touched **only by the writer**. They are not
  /// shared, so no lock is needed to build into them.
  ///
  /// An earlier version kept these in an array both threads indexed, on the
  /// reasoning that distinct indices cannot collide. That is wrong, and it
  /// crashed only in release builds: mutating `buffers[i]` goes through
  /// `Array`'s own storage and its copy-on-write uniqueness check, so a
  /// concurrent read of `buffers[j]` races on the array itself — and since a
  /// snapshot holds a refcounted `instances` array, the race manifests as an
  /// over-release rather than as stale data. Debug builds hid it.
  private var writerBuffers: [FrameSnapshot]
  private var writeIndex = 0

  /// The published snapshot. Guarded by `lock`.
  private var published: FrameSnapshot?
  private let lock = NSLock()

  public init() {
    writerBuffers = Array(repeating: FrameSnapshot(), count: 3)
  }

  /// Builds the next snapshot and publishes it.
  ///
  /// `body` runs entirely outside the lock, against a buffer no other thread
  /// can see. The critical section is a single struct assignment — a handful of
  /// retains — so a slow snapshot build can never stall the renderer, which is
  /// what PC-002 requires.
  public func publish(_ body: (inout FrameSnapshot) -> Void) {
    writeIndex = (writeIndex + 1) % writerBuffers.count
    body(&writerBuffers[writeIndex])
    let ready = writerBuffers[writeIndex]

    lock.lock()
    published = ready
    lock.unlock()
  }

  /// The newest complete snapshot, or nil if nothing has been published.
  ///
  /// Returns a value copy. Copying retains the instance array rather than
  /// duplicating it, so this is cheap; if the writer later needs that buffer
  /// back while the reader still holds it, copy-on-write makes a fresh
  /// allocation instead of corrupting the reader's view. Three rotating buffers
  /// make that rare.
  public func latest() -> FrameSnapshot? {
    lock.lock()
    defer { lock.unlock() }
    return published
  }
}


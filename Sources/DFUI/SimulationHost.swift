import DFCore
import DFSim
import Foundation

/// Runs a fortress on its own thread and publishes snapshots for a renderer.
///
/// The threading contract, stated once here because it is the whole design:
///
/// - **The simulation thread exclusively owns the `Fortress`.** No other thread
///   touches it, ever. That is what makes Constitution III hold at runtime and
///   not merely in the type system.
/// - The UI thread contributes only two things, each behind its own small
///   lock: a queue of `Command`s and the current `Camera`. Both are plain
///   values; neither is a reference into simulation state.
/// - The renderer reads published snapshots through `FrameSnapshotRing`, which
///   is already lock-free for the data itself.
///
/// PC-002 is why the camera is *pulled* by the simulation thread when it
/// publishes, rather than pushed by the UI thread: a push would need the UI to
/// wait on the tick, which makes simulation cost depend on whether a window is
/// open.
///
/// `@unchecked Sendable` covers exactly the two locked fields below. The
/// `Fortress` is not shared despite living in this class — `run()` is the only
/// thing that touches it, and it is called from one thread.
public final class SimulationHost: @unchecked Sendable {
  private let fortress: Fortress
  public let ring: FrameSnapshotRing

  private let lock = NSLock()
  private var inbox: [Command] = []
  /// Swapped with `inbox` under the lock so draining costs no allocation.
  /// Copying `inbox` out and calling `removeAll(keepingCapacity:)` does not
  /// work: the copy keeps the storage referenced, so `removeAll` finds it
  /// non-unique and allocates fresh storage anyway — one malloc/free per tick
  /// forever, for a buffer that is almost always empty.
  private var inboxScratch: [Command] = []
  private var camera: Camera
  private var stopping = false

  /// Ticks per second the simulation targets. 100 is DF's frame cap and the
  /// figure `docs/reference/map-and-time.md` derives the 10 ms budget from.
  public static let ticksPerSecond = 100

  public init(fortress: Fortress, camera: Camera) {
    self.fortress = fortress
    self.ring = FrameSnapshotRing()
    self.camera = camera
  }

  // MARK: - Called from the UI thread

  /// Queues a command produced by input. Applied at the top of the next tick.
  public func submit(_ command: Command) {
    lock.lock()
    inbox.append(command)
    lock.unlock()
  }

  /// Updates what the simulation should snapshot.
  public func setCamera(_ camera: Camera) {
    lock.lock()
    self.camera = camera
    lock.unlock()
  }

  public func stop() {
    lock.lock()
    stopping = true
    lock.unlock()
  }

  // MARK: - Called from the simulation thread only

  /// Advances one tick and publishes a snapshot. Returns false once stopped.
  ///
  /// Separated from the timing loop so a headless test can drive it directly —
  /// Constitution V: a loop that can only be exercised by opening a window
  /// cannot be verified by an agent.
  @discardableResult
  public func stepOnce() -> Bool {
    lock.lock()
    swap(&inbox, &inboxScratch)
    let currentCamera = camera
    let shouldStop = stopping
    lock.unlock()

    if shouldStop { return false }

    // Input becomes commands like any other source, so a recorded session
    // replays identically (SC-004).
    for command in inboxScratch {
      fortress.submit(command)
    }
    inboxScratch.removeAll(keepingCapacity: true)
    fortress.step()

    // Built *into* the ring's writer buffer, not assigned over it. The ring
    // rotates three buffers precisely so the writer can reuse their storage,
    // and `buildSnapshot` only reallocates when the instance count changes --
    // but `snapshot(camera:)` hands it a fresh empty FrameSnapshot every time,
    // which makes that check fail every tick and defeats both mechanisms. At a
    // 300x200 camera that was ~2.8 MiB allocated, zero-filled, overwritten and
    // freed per tick.
    ring.publish { fortress.buildSnapshot(camera: currentCamera, tileset: .ascii, into: &$0) }
    return true
  }

  /// Runs until `stop()`, pacing to `ticksPerSecond`.
  ///
  /// Deliberately a plain sleep-to-deadline loop rather than a timer: it must
  /// not be tied to the display, and falling behind must drop the surplus
  /// rather than accumulate a backlog it can never work off.
  public func run() {
    let tickDuration = 1.0 / Double(SimulationHost.ticksPerSecond)
    var deadline = Date().timeIntervalSinceReferenceDate

    while stepOnce() {
      deadline += tickDuration
      let now = Date().timeIntervalSinceReferenceDate
      if now < deadline {
        Thread.sleep(forTimeInterval: deadline - now)
      } else if now > deadline + tickDuration {
        // Behind by more than a whole tick: give up on catching up rather than
        // spinning. A fortress that cannot keep up should run slow, not freeze
        // trying to run fast.
        deadline = now
      }
    }
  }

  /// The current state hash. Simulation-thread only; used by tests.
  public var stateHash: UInt64 { fortress.stateHash }

  /// Ticks elapsed. Simulation-thread only.
  public var tick: UInt64 { fortress.tick }

  /// The recorded command stream, for writing a replay fixture.
  ///
  /// Exposed so `dfsim ui-session` can drive this host rather than
  /// re-implementing `stepOnce()`. That matters beyond tidiness: the snapshot
  /// path is going to change when per-block dirty-flag reuse lands, and a
  /// fixture or bench that hand-rolled the loop would keep exercising the code
  /// that was replaced.
  public var recording: [TimedCommand] { fortress.commands.recording }
}

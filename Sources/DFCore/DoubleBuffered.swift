/// Two same-sized buffers that swap roles each tick.
///
/// Built for stencil systems: `JobSystem.parallelStencil` needs a
/// previous-tick buffer to read and a different next-tick buffer to write,
/// and this supplies both without allocating fresh storage every tick.
/// `front` is what the current tick reads; `back` is what it writes; `swap()`
/// exchanges the two roles once the tick's writes are complete, so next
/// tick's front is this tick's back -- never the buffer a worker just wrote
/// mid-pass, which is the in-place-stencil hazard the constitution's
/// "stencil systems double-buffer" rule exists to rule out.
///
/// A class, like `MapStore`, for the same reason: the buffers are manually
/// managed memory with a single logical owner, not a value meant to be
/// copied. `@unchecked Sendable` covers exactly that single-owner-thread
/// model -- nothing here is safe to mutate from two threads at once, only to
/// read `front`/write `back` concurrently within one `parallelStencil` call,
/// which is disjoint by construction.
public final class DoubleBuffered<Element>: @unchecked Sendable {
  private var buffers: (UnsafeMutableBufferPointer<Element>, UnsafeMutableBufferPointer<Element>)
  private var frontIsFirst = true

  public init(count: Int, repeating initial: Element) {
    let first = UnsafeMutableBufferPointer<Element>.allocate(capacity: count)
    let second = UnsafeMutableBufferPointer<Element>.allocate(capacity: count)
    first.initialize(repeating: initial)
    second.initialize(repeating: initial)
    buffers = (first, second)
  }

  deinit {
    buffers.0.baseAddress?.deinitialize(count: buffers.0.count)
    buffers.0.deallocate()
    buffers.1.baseAddress?.deinitialize(count: buffers.1.count)
    buffers.1.deallocate()
  }

  public var count: Int { buffers.0.count }

  /// The previous-tick buffer. Read-only by type, not merely by convention:
  /// there is no mutating accessor through this view, which is what makes it
  /// safe to share across every `parallelStencil` worker without a lock --
  /// there is nothing for two readers to race on.
  public var front: UnsafeBufferPointer<Element> {
    UnsafeBufferPointer(frontIsFirst ? buffers.0 : buffers.1)
  }

  /// The next-tick buffer. A stencil pass writes each disjoint slot into this
  /// exactly once; nothing reads it as "current" until `swap()` runs.
  public var back: UnsafeMutableBufferPointer<Element> {
    frontIsFirst ? buffers.1 : buffers.0
  }

  /// Exchanges front and back. Call once, after a tick's writes into `back`
  /// are complete and before the next tick's reads -- never mid-tick, which
  /// would let one worker's read observe another worker's write from the same
  /// pass and reintroduce the exact ordering dependency double-buffering
  /// exists to remove.
  public func swap() {
    frontIsFirst.toggle()
  }
}

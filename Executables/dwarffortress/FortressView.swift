import AppKit
import DFCore
import DFRender
import DFSim
import DFUI
import Metal
import QuartzCore

/// Draws published snapshots, on the display link's thread.
///
/// Split from `FortressView` because the two live on different threads and
/// owning different things is what keeps that honest. `CAMetalDisplayLink`
/// calls its delegate on its own thread, not the main one, so this object —
/// and the `TilemapRenderer` it owns — must never be touched from the UI side.
/// The only things crossing the boundary are `FrameSnapshotRing`, which is
/// built for it, and the layer itself, which Core Animation handles.
///
/// `@unchecked Sendable` is carrying exactly that claim: single-threaded
/// ownership by the display link, not internal locking.
final class FrameDrawer: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
  private let renderer: TilemapRenderer
  private let ring: FrameSnapshotRing

  init(renderer: TilemapRenderer, ring: FrameSnapshotRing) {
    self.renderer = renderer
    self.ring = ring
  }

  func metalDisplayLink(
    _ link: CAMetalDisplayLink,
    needsUpdate update: CAMetalDisplayLink.Update
  ) {
    guard let snapshot = ring.latest(), !snapshot.isEmpty else { return }

    // `makeCommandBuffer` blocks until a frame slot is free and releases it on
    // completion. The in-flight limit lives in the renderer because the thing
    // it protects — instance-buffer rotation — is the renderer's; this loop no
    // longer has to remember it. Blocking here is safe only because this
    // delegate runs on `renderThread`, not on main.
    guard let commandBuffer = renderer.makeCommandBuffer() else { return }

    do {
      try renderer.draw(snapshot, into: update.drawable.texture, commandBuffer: commandBuffer)
    } catch {
      // Still commit: the slot is released by the completion handler, and an
      // uncommitted buffer would never fire one.
      commandBuffer.commit()
      return
    }
    commandBuffer.present(update.drawable)
    commandBuffer.commit()
  }
}

/// The window's content: a `CAMetalLayer` plus input handling.
///
/// Everything here is translation. Decisions — what a key means, which tile a
/// click hit, where the camera may go — live in `DFUI` and are tested there.
/// This class turns `NSEvent` into `DFUI` types, and is kept thin precisely
/// because it is the one part of M1 no headless test can reach.
final class FortressView: NSView {
  private let host: SimulationHost
  private let inputMap = InputMap()
  private let drawer: FrameDrawer
  private var controller: CameraController
  private var renderThread: Thread?

  /// Held rather than re-derived by casting `layer`: this class creates it, so
  /// the cast could only ever fail if someone reassigned `layer` underneath.
  private let metalLayer = CAMetalLayer()

  init(host: SimulationHost, renderer: TilemapRenderer, controller: CameraController) {
    self.host = host
    self.controller = controller
    self.drawer = FrameDrawer(renderer: renderer, ring: host.ring)
    super.init(frame: .zero)

    wantsLayer = true
    layer = metalLayer
    metalLayer.device = renderer.device
    metalLayer.pixelFormat = TilemapRenderer.pixelFormat
    metalLayer.framebufferOnly = true
    // Nearest-neighbour all the way to the screen. Filtering here would blur
    // the glyph grid, and the grid is the whole readability argument.
    metalLayer.magnificationFilter = .nearest
    metalLayer.minificationFilter = .nearest
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

  override var acceptsFirstResponder: Bool { true }

  // MARK: - Display link

  /// Starts the display link on a dedicated thread.
  ///
  /// **Not the main run loop.** `CAMetalDisplayLink` delivers its callback on
  /// whichever run loop it was added to, and the callback both blocks on the
  /// renderer's in-flight semaphore and does a multi-megabyte instance copy.
  /// On `.main` that stalls event handling and live resize whenever the GPU
  /// falls a frame behind — and it would have quietly falsified `FrameDrawer`'s
  /// whole threading rationale, which is written assuming it is off main.
  func startDrawing() {
    // `CAMetalLayer` is not `Sendable`, but handing it to a display link on
    // another thread is the documented way to drive one: Core Animation owns
    // the cross-thread synchronisation for the layer's drawable queue, and
    // this thread only ever asks the link for drawables. Nothing else touches
    // the layer from here.
    nonisolated(unsafe) let layerForLink = metalLayer
    let thread = Thread { [drawer] in
      let link = CAMetalDisplayLink(metalLayer: layerForLink)
      link.delegate = drawer
      link.add(to: .current, forMode: .common)
      // The link retains itself in the run loop; this parks the thread until
      // `invalidate()` lets the run loop drain and return.
      while !Thread.current.isCancelled,
        RunLoop.current.run(mode: .common, before: .distantFuture) {}
      link.invalidate()
    }
    thread.name = "render"
    thread.qualityOfService = .userInteractive
    thread.start()
    renderThread = thread
  }

  /// Signals the render thread to unwind. It invalidates its own link once the
  /// run loop returns, which the next display callback wakes it to do — the
  /// link is owned by that thread and must not be torn down from this one.
  func stopDrawing() {
    renderThread?.cancel()
    renderThread = nil
  }

  // MARK: - Sizing

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateDrawableSize()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateDrawableSize()
  }

  private func updateDrawableSize() {
    let scale = window?.backingScaleFactor ?? 1
    // A window mid-resize can report zero, and CAMetalLayer rejects a zero
    // drawable. The spec lists surviving this as a requirement, so clamp here
    // rather than pass it through.
    let pixelWidth = max(1, Int(bounds.width * scale))
    let pixelHeight = max(1, Int(bounds.height * scale))
    metalLayer.drawableSize = CGSize(width: pixelWidth, height: pixelHeight)
    metalLayer.contentsScale = scale

    // Only publish when the tile-space camera actually moved. AppKit calls
    // this continuously during a live drag, and most of those pixel deltas do
    // not cross a tile boundary, so taking the host's lock each time would be
    // contention for no change.
    if controller.resize(pixelWidth: pixelWidth, pixelHeight: pixelHeight) {
      host.setCamera(controller.camera)
    }
  }

  // MARK: - Input

  override func keyDown(with event: NSEvent) {
    guard let stroke = FortressView.stroke(from: event) else {
      super.keyDown(with: event)
      return
    }
    apply(inputMap.action(for: stroke))
  }

  override func mouseDown(with event: NSEvent) {
    let local = convert(event.locationInWindow, from: nil)
    let scale = window?.backingScaleFactor ?? 1
    // AppKit's origin is bottom-left; the camera, the capture and the ASCII
    // dump all use top-left. Flipping here keeps that one convention true
    // everywhere below this line.
    let click = Click(
      x: Double(local.x * scale),
      y: Double((bounds.height - local.y) * scale))
    apply(
      inputMap.action(
        for: click, camera: controller.camera, pixelsPerTile: controller.pixelsPerTile))
  }

  private func apply(_ action: InputAction) {
    switch action {
    case .view(let viewAction):
      // DR-001 at the call site: a view action's only effect is the camera.
      if controller.apply(viewAction) {
        host.setCamera(controller.camera)
      }
    case .fortress(let command):
      host.submit(command)
    case .ignored:
      break
    }
  }

  private static func stroke(from event: NSEvent) -> KeyStroke? {
    let shift = event.modifierFlags.contains(.shift)
    switch Int(event.keyCode) {
    case 123: return KeyStroke(.left, shift: shift)
    case 124: return KeyStroke(.right, shift: shift)
    case 126: return KeyStroke(.up, shift: shift)
    case 125: return KeyStroke(.down, shift: shift)
    case 116: return KeyStroke(.pageUp, shift: shift)
    case 121: return KeyStroke(.pageDown, shift: shift)
    default:
      guard let characters = event.charactersIgnoringModifiers,
        let character = characters.first
      else { return nil }
      return KeyStroke(.character(character), shift: shift)
    }
  }
}

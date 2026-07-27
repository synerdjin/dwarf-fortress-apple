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

  /// Bounds how many frames may be encoded before one completes. Matches the
  /// renderer's instance-buffer rotation exactly — encoding a fourth frame
  /// while three are outstanding would reuse a buffer the GPU is still
  /// reading. See `TilemapRenderer.maxFramesInFlight`.
  private let inFlight: DispatchSemaphore

  init(renderer: TilemapRenderer, ring: FrameSnapshotRing) {
    self.renderer = renderer
    self.ring = ring
    self.inFlight = DispatchSemaphore(value: TilemapRenderer.maxFramesInFlight)
  }

  func metalDisplayLink(
    _ link: CAMetalDisplayLink,
    needsUpdate update: CAMetalDisplayLink.Update
  ) {
    guard let snapshot = ring.latest(), !snapshot.isEmpty else { return }

    inFlight.wait()
    guard let commandBuffer = renderer.makeCommandBuffer() else {
      inFlight.signal()
      return
    }
    // Registered before any early return below, so no path can drop a signal
    // and wedge the loop three frames later.
    let semaphore = inFlight
    commandBuffer.addCompletedHandler { _ in semaphore.signal() }

    do {
      try renderer.draw(snapshot, into: update.drawable.texture, commandBuffer: commandBuffer)
    } catch {
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
  private var displayLink: CAMetalDisplayLink?

  private var metalLayer: CAMetalLayer {
    guard let metal = layer as? CAMetalLayer else {
      preconditionFailure("FortressView's layer must be a CAMetalLayer")
    }
    return metal
  }

  init(host: SimulationHost, renderer: TilemapRenderer, controller: CameraController) {
    self.host = host
    self.controller = controller
    self.drawer = FrameDrawer(renderer: renderer, ring: host.ring)
    super.init(frame: .zero)

    wantsLayer = true
    layer = CAMetalLayer()
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

  func startDrawing() {
    let link = CAMetalDisplayLink(metalLayer: metalLayer)
    link.delegate = drawer
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  func stopDrawing() {
    displayLink?.invalidate()
    displayLink = nil
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

    controller.resize(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    host.setCamera(controller.camera)
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

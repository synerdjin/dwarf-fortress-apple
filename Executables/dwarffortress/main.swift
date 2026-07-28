import AppKit
import DFCore
import DFECS
import DFRender
import DFSim
import DFUI

/// `swift run dwarffortress` — a bare window on a running fortress.
///
/// SC-001 in the form the spec settled on: launched from the command line, no
/// `.app` bundle, no Info.plist, no code signing. `NSApplication` needs
/// `.regular` activation policy set by hand for a window to appear and take
/// focus without one.
///
/// This file owns process lifetime and nothing else. The simulation runs on its
/// own thread inside `SimulationHost`; drawing and input live in `FortressView`.

let arguments = CommandLine.arguments
func option(_ name: String, default fallback: Int) -> Int {
  guard let index = arguments.firstIndex(of: "--\(name)"),
    index + 1 < arguments.count,
    let value = Int(arguments[index + 1])
  else { return fallback }
  return value
}

func stringOption(_ name: String, default fallback: String) -> String {
  guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else {
    return fallback
  }
  return arguments[index + 1]
}

let scenarioName = stringOption("scenario", default: "small-dig")
guard let scenario = Scenario.named(scenarioName) else {
  let available = Scenario.all.map(\.name).joined(separator: ", ")
  FileHandle.standardError.write(
    Data("unknown scenario '\(scenarioName)'. Available: \(available)\n".utf8))
  exit(2)
}

let renderer: TilemapRenderer
do {
  renderer = try TilemapRenderer()
} catch {
  FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
  exit(1)
}

// `isRecording: true` so a session can be written out as a fixture (T014).
let fortress = Fortress.make(
  scenario: scenario, seed: UInt64(option("seed", default: 1)), jobs: JobSystem(),
  isRecording: true)

// The viewport opens no larger than the map. Showing more tiles than exist
// just renders empty space, which is what the first version of this did: on a
// 64x48 map it opened a 160x77 viewport and 60% of the window was blank.
let visibleTiles = Coord3(
  min(80, fortress.map.size.x),
  min(40, fortress.map.size.y),
  1)
var controller = CameraController(
  camera: Camera(
    origin: Coord3(0, 0, Int32(option("z", default: Int(scenario.mapSize.z) - 2))),
    size: visibleTiles,
    depthLayers: option("layers", default: 2)),
  pixelsPerTile: option("zoom", default: 8),
  mapSize: fortress.map.size)
// Read back, not the raw option: CameraController clamps zoom to [4, 32], and
// the window must be sized from the value actually in force or the two
// disagree about how big a tile is.
let pixelsPerTile = controller.pixelsPerTile

let host = SimulationHost(fortress: fortress, camera: controller.camera)

// One snapshot before the window opens, so the first frame the display link
// asks for has something to draw rather than a blank layer.
host.stepOnce()

let application = NSApplication.shared
application.setActivationPolicy(.regular)

let view = FortressView(host: host, renderer: renderer, controller: controller)

// `pixelsPerTile` is in *device* pixels -- that is the unit FortressView
// divides the drawable by, and keeping tiles an exact pixel multiple is what
// keeps nearest-neighbour sampling crisp. NSWindow takes points. Dividing by
// the screen's backing scale is what makes the window show the tile count
// asked for: without it, a Retina display got exactly twice as many tiles as
// intended, which is the bug that left most of the window blank.
let backingScale = NSScreen.main?.backingScaleFactor ?? 1
let contentSize = NSSize(
  width: CGFloat(Int(controller.camera.size.x) * pixelsPerTile) / backingScale,
  height: CGFloat(Int(controller.camera.size.y) * pixelsPerTile) / backingScale)
let window = NSWindow(
  contentRect: NSRect(origin: .zero, size: contentSize),
  styleMask: [.titled, .closable, .miniaturizable, .resizable],
  backing: .buffered,
  defer: false)
window.title = "Dwarf Fortress — \(scenario.name)"
window.contentView = view
window.center()
window.makeFirstResponder(view)
window.makeKeyAndOrderFront(nil)

let simulationThread = Thread { host.run() }
simulationThread.name = "simulation"
// The tick loop is the latency-sensitive path; the same reasoning as
// `JobSystem.Workload.simulation`.
simulationThread.qualityOfService = .userInteractive
simulationThread.start()

let delegate = AppDelegate(host: host, view: view)
application.delegate = delegate

view.startDrawing()
application.activate(ignoringOtherApps: true)
application.run()

/// Stops the simulation thread when the window closes, so `swift run` returns
/// instead of leaving a detached thread spinning.
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let host: SimulationHost
  private let view: FortressView

  init(host: SimulationHost, view: FortressView) {
    self.host = host
    self.view = view
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationWillTerminate(_ notification: Notification) {
    view.stopDrawing()
    host.stop()
  }
}

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

let scenarioName = arguments.firstIndex(of: "--scenario").map { arguments[$0 + 1] } ?? "small-dig"
guard let scenario = Scenario.all.first(where: { $0.name == scenarioName }) else {
  FileHandle.standardError.write(
    "unknown scenario \(scenarioName); try: \(Scenario.all.map(\.name).joined(separator: ", "))\n"
      .data(using: .utf8)!)
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

let pixelsPerTile = option("zoom", default: 8)
var controller = CameraController(
  camera: Camera(
    origin: Coord3(0, 0, Int32(option("z", default: Int(scenario.mapSize.z) - 2))),
    size: Coord3(80, 40, 1),
    depthLayers: option("layers", default: 2)),
  pixelsPerTile: pixelsPerTile,
  mapSize: fortress.map.size)

let host = SimulationHost(fortress: fortress, camera: controller.camera)

// One snapshot before the window opens, so the first frame the display link
// asks for has something to draw rather than a blank layer.
host.stepOnce()

let application = NSApplication.shared
application.setActivationPolicy(.regular)

let view = FortressView(host: host, renderer: renderer, controller: controller)
let window = NSWindow(
  contentRect: NSRect(
    x: 0, y: 0,
    width: CGFloat(80 * pixelsPerTile), height: CGFloat(40 * pixelsPerTile)),
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

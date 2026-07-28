// Prints "<windowNumber> <area>" for every normal window owned by a pid,
// where "normal" means layer 0.
//
// The layer filter is load-bearing, not tidiness. A process owns more windows
// than the one you can see: this app also owns four full-width menu-bar strips
// at layer 25, and picking "the widest window" selected one of those and
// captured a 3420x68 sliver of menu bar instead of the fortress.
//
// Used by Scripts/window-shot.sh to find the app's content window without
// AppleScript. `System Events` would need Accessibility permission -- which is
// permission to *control* the machine, far more than looking at it warrants --
// whereas CGWindowList needs only the Screen Recording grant the capture
// itself already requires.
//
// Not part of the SwiftPM package: it lives in Scripts/, which no target
// declares, and runs as `swift Scripts/window-id.swift <pid>`.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
  FileHandle.standardError.write(Data("usage: window-id.swift <pid>\n".utf8))
  exit(2)
}

let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows {
  guard let owner = window[kCGWindowOwnerPID as String] as? Int32, owner == pid,
    let number = window[kCGWindowNumber as String] as? Int,
    let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
    let bounds = window[kCGWindowBounds as String] as? [String: Any],
    let width = bounds["Width"] as? Double,
    let height = bounds["Height"] as? Double
  else { continue }
  print("\(number) \(Int(width * height))")
}

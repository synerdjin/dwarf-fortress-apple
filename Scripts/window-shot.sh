#!/bin/bash
# Capture the dwarffortress window to a PNG, so an agent can *look at* the app.
#
# Constitution V says a subsystem that can only be exercised by launching the
# app and looking at it is one an agent cannot verify. The window was exactly
# that until this script existed, and it cost three bugs to learn: a viewport
# sized off by the backing scale factor, a blank window from an unrunnable run
# loop mode, and a dead display-link property. All three passed every gate in
# Scripts/ci.sh, and all three were caught by a human sending a screenshot.
#
# Requires: Screen Recording permission for the terminal or app running this
# (System Settings > Privacy & Security > Screen & System Audio Recording).
# Without it, screencapture fails with "could not create image from display".
# No Accessibility permission is needed or wanted -- window lookup goes through
# CGWindowList, not AppleScript.
#
# Usage:
#   Scripts/window-shot.sh [out.png] [-- <dwarffortress args>]
#
#   Scripts/window-shot.sh                       # capture a running instance,
#                                                # or launch one with defaults
#   Scripts/window-shot.sh /tmp/f.png -- --zoom 24 --scenario small-dig
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-out/window.png}"
[ $# -gt 0 ] && shift || true
[ "${1:-}" = "--" ] && shift || true
APP_ARGS=("$@")
[ ${#APP_ARGS[@]} -eq 0 ] && APP_ARGS=(--scenario small-dig --zoom 24)

mkdir -p "$(dirname "$OUT")"

launched=0
if ! pgrep -x dwarffortress > /dev/null; then
  swift build -c release --product dwarffortress > /dev/null
  # Frame logging on: a window that is up but drawing nothing looks identical
  # to a working one in `ps`, and reads as *lower* CPU.
  DF_FRAME_LOG=1 nohup "$(swift build -c release --show-bin-path)/dwarffortress" \
    "${APP_ARGS[@]}" > out/window-shot.log 2>&1 &
  launched=1
  sleep 3
fi

PID="$(pgrep -x dwarffortress | head -1)"
if [ -z "$PID" ]; then
  echo "dwarffortress is not running and could not be started; see out/window-shot.log" >&2
  exit 1
fi

# Largest window owned by the process: its content window, not the menu bar
# strips that also belong to it.
WID="$(swift Scripts/window-id.swift "$PID" |  sort -k2 -rn | head -1 | cut -d' ' -f1)"
if [ -z "$WID" ]; then
  echo "no window found for pid $PID" >&2
  exit 1
fi

screencapture -x -l "$WID" "$OUT"
echo "captured $OUT (window $WID of pid $PID)"

if [ -f out/window-shot.log ]; then
  echo "frames: $(tail -1 out/window-shot.log 2>/dev/null || echo 'no frame log')"
fi

# A window that is occluded captures at reduced size, which is a rendering
# artifact of the capture and not of the app. Say so rather than let a small
# image be mistaken for a small window.
DIMS="$(sips -g pixelWidth -g pixelHeight "$OUT" 2>/dev/null | tail -2 | tr -d ' \n')"
echo "size: $DIMS  (a partly covered window captures downscaled; front it for full resolution)"

[ "$launched" = "1" ] && echo "note: this script launched the app; it is still running (pkill -x dwarffortress)"
exit 0

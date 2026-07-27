#!/bin/bash
# The merge gate. If this is red, the change does not land.
#
# Deliberately runnable with Command Line Tools alone -- no Xcode, no XCTest,
# no swift-testing. An agent that cannot run the gate cannot do the work.
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
fail() { printf '\033[31mFAILED: %s\033[0m\n' "$1"; exit 1; }

step "Build (debug)"
swift build || fail "debug build"

step "Build (release)"
swift build -c release || fail "release build"

step "Unit tests (debug)"
swift run dftest || fail "unit tests (debug)"

step "Unit tests (release)"
# Debug and release are demonstrably different programs here -- see
# docs/known-issues.md KI-001, a release-only crash that hid for two milestones
# because only debug was routinely exercised. Both configurations are gates.
swift run -c release dftest || fail "unit tests (release)"

step "Replay fixtures"
# Golden hashes are contracts between agents. If your change moves them, that is
# a conversation with the owning agent, not a re-blessing of the fixture.
shopt -s nullglob
fixtures=(Fixtures/replays/*.rec)
if [ ${#fixtures[@]} -eq 0 ]; then
  echo "no replay fixtures found -- skipping"
else
  for fixture in "${fixtures[@]}"; do
    echo "--- $fixture"
    swift run -c release dfsim replay "$fixture" --assert-hashes \
      || fail "replay $fixture"
  done
fi

step "Determinism across partition counts"
# Results must be independent of how work was decomposed, not merely race-free.
for scenario in small-dig 200-dwarves; do
  echo "--- $scenario"
  swift run -c release dfsim determinism-check \
    --scenario "$scenario" --ticks 3000 --threads 1,2,3,7,16,64 \
    || fail "determinism-check $scenario"
done

step "Headless render capture"
# SC-002/SC-003: the GPU path must agree with the ASCII path and be
# reproducible. Skipped rather than failed where no GPU is reachable.
mkdir -p out
# A crash must not be reported as "no GPU". Probe for a device first, then
# treat any capture failure as a real failure -- an earlier version of this
# script swallowed a release-only SIGTRAP as "no GPU reachable" and reported
# all gates passed while `shot` was broken.
if swift run -c release dfsim scenarios > /dev/null 2>&1 \
   && system_profiler SPDisplaysDataType 2>/dev/null | grep -q Metal; then
  swift run -c release dfsim shot --scenario small-dig --tick 4000 \
    --width 40 --height 24 --out out/ci-frame.png > /dev/null \
    || fail "dfsim shot failed (exit $?)"
  echo "captured out/ci-frame.png"
  swift run -c release dfsim shot --scenario small-dig --tick 4000 \
    --width 40 --height 24 --out out/ci-frame-2.png | grep pixelHash
  cmp -s out/ci-frame.png out/ci-frame-2.png \
    || fail "two captures of the same state differ (DR-003)"
  echo "two captures byte-identical"
else
  echo "no Metal device advertised -- capture skipped"
fi

step "Performance budgets"
# M0 has no enforced budget; the number is recorded so a regression is visible
# in CI output before M3 attaches a real threshold to it.
swift run -c release dfsim bench --scenario 200-dwarves --ticks 5000 \
  || fail "bench"

printf '\n\033[32mAll gates passed.\033[0m\n'

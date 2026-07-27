#!/bin/bash
# The merge gate. If this is red, the change does not land.
#
# Deliberately runnable with Command Line Tools alone -- no Xcode, no XCTest,
# no swift-testing. An agent that cannot run the gate cannot do the work.
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
fail() { printf '\033[31mFAILED: %s\033[0m\n' "$1"; exit 1; }

# The target platform is Apple Silicon, which always has a Metal device, so the
# default is that GPU work must run. Set CI_ALLOW_NO_GPU=1 only on a runner that
# genuinely has none (the GitHub hosted macOS runners do not) -- and know that
# it downgrades real coverage, so a green run under it proves less.
: "${CI_ALLOW_NO_GPU:=0}"
if [ "$CI_ALLOW_NO_GPU" = "1" ]; then
  max_skips=99
  printf '\033[33mCI_ALLOW_NO_GPU=1: GPU tests may skip; this run proves less.\033[0m\n'
else
  max_skips=0
fi

step "Test suites are registered"
# Suites are registered by hand in DFTests/main.swift, which is the honest
# design -- Swift has no runtime discovery without a test framework. Its failure
# mode is a test file nobody registered, which never runs and never says so.
unregistered=""
while IFS= read -r fn; do
  grep -q "^\s*${fn}()" Sources/DFTests/main.swift || unregistered="$unregistered $fn"
done < <(grep -rhoE '^func (register[A-Za-z0-9]*Tests)' Sources/DFTests | awk '{print $2}')
if [ -n "$unregistered" ]; then
  fail "test suites defined but never registered in DFTests/main.swift:$unregistered"
fi
echo "every register*Tests is called"

step "Spec-ID traceability"
# A test named for a spec ID that no spec declares traces to nothing. Both
# directions of that link have to hold or the naming convention is decoration.
declared=$(grep -rhoE 'SPEC-M[0-9]+-[A-Z]+' specs/*/spec.md | sort -u)
dangling=""
for id in $(grep -rhoE 'SPEC-M[0-9]+-[A-Z]+' Sources | sort -u); do
  printf '%s\n' "$declared" | grep -qx "$id" || dangling="$dangling $id"
done
if [ -n "$dangling" ]; then
  fail "code cites spec IDs that no specs/*/spec.md declares:$dangling"
fi
echo "every cited spec ID is declared"

step "Build (debug)"
swift build || fail "debug build"

step "Build (release)"
swift build -c release || fail "release build"

step "Unit tests (debug)"
# --max-skips is what stops a skip from reading as a pass. `expect(true,
# "skipped")` used to print a ✓ and exit 0, so "the GPU tests stopped running"
# and "the GPU tests passed" were the same observation.
swift run dftest --max-skips "$max_skips" || fail "unit tests (debug)"

step "Unit tests (release)"
# Debug and release are demonstrably different programs here -- see
# docs/known-issues.md KI-001, a release-only crash that hid for two milestones
# because only debug was routinely exercised. Both configurations are gates.
swift run -c release dftest --max-skips "$max_skips" || fail "unit tests (release)"

step "Replay fixtures"
# Golden hashes are contracts between agents. If your change moves them, that is
# a conversation with the owning agent, not a re-blessing of the fixture.
#
# Named, not globbed. A glob that matches nothing exits 0, so deleting the
# fixtures -- or a rename, or running from the wrong directory -- read as
# "replay gate passed". Every fixture the project relies on is listed here by
# name and its absence is a failure.
required_fixtures=(Fixtures/replays/smoke.rec Fixtures/replays/ui-session.rec)
for fixture in "${required_fixtures[@]}"; do
  [ -f "$fixture" ] || fail "required fixture $fixture is missing"
done

shopt -s nullglob
fixtures=(Fixtures/replays/*.rec)
for fixture in "${fixtures[@]}"; do
  echo "--- $fixture"
  swift run -c release dfsim replay "$fixture" --assert-hashes \
    || fail "replay $fixture"
done

step "Determinism across partition counts"
# Results must be independent of how work was decomposed, not merely race-free.
for scenario in small-dig 200-dwarves render-300x200; do
  echo "--- $scenario"
  swift run -c release dfsim determinism-check \
    --scenario "$scenario" --ticks 3000 --threads 1,2,3,7,16,64 \
    || fail "determinism-check $scenario"
done

step "Headless render capture"
# SC-002/SC-003: the GPU path must agree with the ASCII path and be
# reproducible.
mkdir -p out

# The CLI must start. This ran inside the capture-step `if` condition, which
# meant a release-only crash in CLI startup made the condition false and the
# script printed "no Metal device advertised -- capture skipped" and exited 0.
# That is the historical KI-001 bug (a swallowed SIGTRAP reported as a green
# run) reappearing in the very line written to prevent it: the fix had been
# applied to the crashing command and not to the pattern of gating on success.
# The only thing allowed to decide a skip is the hardware probe.
swift run -c release dfsim scenarios > /dev/null || fail "dfsim scenarios (CLI startup)"

if system_profiler SPDisplaysDataType 2>/dev/null | grep -q Metal; then
  have_gpu=1
elif [ "$CI_ALLOW_NO_GPU" = "1" ]; then
  have_gpu=0
else
  fail "no Metal device advertised; set CI_ALLOW_NO_GPU=1 if that is genuinely true"
fi

if [ "$have_gpu" = "1" ]; then
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
  echo "CI_ALLOW_NO_GPU=1 and no Metal device -- capture skipped"
fi

step "Performance budgets"
# M3 sets the real budget from a measured prototype (backlog item 11). Until
# then this is a regression tripwire, not a target: --budget-ms is passed so a
# regression is an exit code, because agents read exit codes and not logs. The
# gate did print the number before, and nothing failed when it got worse.
#
# Measured 2026-07-27, 200 dwarves, 5000 ticks:
#   Apple Silicon dev machine  0.093 ms/tick  (three runs: .0928 .0930 .0946)
#   GitHub hosted macOS runner 0.18  ms/tick
# The threshold is 3x the slower of the two, so CI's own hardware variance
# cannot redden the build while a genuine algorithmic regression still does.
swift run -c release dfsim bench --scenario 200-dwarves --ticks 5000 \
  --budget-ms 0.55 \
  || fail "bench exceeded its budget"

# PC-002: a window must not add more than 1 ms/tick to simulation cost.
#
# Measured 2026-07-27 on an Apple M4, 200 dwarves, camera clamped to the
# 144x144 map, 4 layers: 1.014 ms/tick with snapshot publication against
# 0.095 without, so the snapshot itself costs ~0.92 ms/tick. That is inside
# PC-002, but only just, and it does NOT hold at PC-001's own viewport --
# see the render-300x200 gate below. The threshold here is 3x the measured
# total, matching the tripwire convention above: it catches an algorithmic
# regression without reddening on hardware variance.
swift run -c release dfsim bench --scenario 200-dwarves --ticks 3000 \
  --with-snapshot --budget-ms 3.1 \
  || fail "snapshot-publication bench exceeded its budget (PC-002)"

# PC-001 scale. Recorded as a measurement, not yet as a passing budget:
# at 300x200 with 4 layers the snapshot costs ~2.48 ms/tick (2.779 total
# against a 0.301 baseline), which is 2.5x what PC-002 allows. The cause is
# known and is not a regression -- `buildSnapshot` rebuilds every visible
# tile every tick, because the per-block dirty-flag reuse the plan's Cost
# Control section describes was never implemented, and implementing it needs
# the sim-owned dirty bits of P1 backlog item 9. Tracked in docs/state.md.
# The budget below is a 3x tripwire on today's number so the situation cannot
# quietly get worse while the real fix is scheduled.
swift run -c release dfsim bench --scenario render-300x200 --ticks 2000 \
  --with-snapshot --budget-ms 8.4 \
  || fail "render-300x200 snapshot bench exceeded its budget (PC-001 scale)"

printf '\n\033[32mAll gates passed.\033[0m\n'

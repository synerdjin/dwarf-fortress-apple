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

step "Unit tests"
swift run dftest || fail "unit tests"

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
    --scenario "$scenario" --ticks 3000 --threads 1,2,4 \
    || fail "determinism-check $scenario"
done

step "Performance budgets"
# M0 has no enforced budget; the number is recorded so a regression is visible
# in CI output before M3 attaches a real threshold to it.
swift run -c release dfsim bench --scenario 200-dwarves --ticks 5000 \
  || fail "bench"

printf '\n\033[32mAll gates passed.\033[0m\n'

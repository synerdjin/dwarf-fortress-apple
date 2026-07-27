# dwarf-fortress-apple

A Dwarf Fortress–class colony simulation with full simulation depth, native to
macOS on Apple Silicon. Swift 6, data-oriented ECS, Metal tilemap renderer.

Read `docs/ARCHITECTURE.md` before your first change. Read the milestone spec in
`docs/specs/` before implementing anything in it.

## The five invariants

These are not style preferences. Each one exists because a specific class of bug
becomes undetectable without it, and this project is built by agents that cannot
watch a fortress for forty hours to notice corruption. Violating one is a
correctness bug, not a nitpick — reviewers reject on sight.

### 1. No floating point in simulation state

All sim math is integer or `Fixed` (Q16.16, in `DFCore`). Floats are permitted
only in `DFRender`, `DFUI`, and worldgen *intermediate* stages whose results are
quantized to integers before entering sim state.

*Why:* float results vary with instruction selection, vectorization and
evaluation order. Once a float lands in sim state, replay stops being bit-exact
and every regression test in the project quietly becomes a coin flip.

### 2. All randomness flows through a named `RNGStream`

Draw from a per-subsystem stream derived from the world seed:
`RNGStream(seed: worldSeed, .combat)`. Never `Int.random`, never
`SystemRandomNumberGenerator`, never a shared mutable global generator.

*Why:* separate streams mean adding a die roll to combat cannot shift the
sequence that worldgen or moods observe. Shared streams make every change a
global change.

### 3. Sim state is mutated only by applying `Command` values from a queue

UI, input, and AI *produce* commands. The tick loop *consumes* them in
deterministic order. No code outside a system's tick function writes sim state.

*Why:* this single rule buys replay, save-scumming, undo, and future networking.
It is also what makes `dfsim replay --assert-hashes` a real regression net rather
than a smoke test.

### 4. Component types must be `BitwiseCopyable`

No `class`, `String`, `Array`, or any other reference or heap type inside
component data. Strings intern to `SymbolID: UInt32` via `StringTable`.

*Why:* ARC traffic in a loop over 100k entities is the difference between a
playable fortress and a slideshow, and bitwise-copyable components make
serialization a bulk copy instead of a graph walk.

### 5. Every module ships unit tests and a headless `dfsim` verb

If a subsystem can only be exercised by launching the app and looking at it, an
agent cannot verify it. Add the verb in the same change as the feature.

## Verification

Never report work as done without running these. `Scripts/ci.sh` is the merge gate.

```bash
Scripts/ci.sh                                    # build + test + replays + bench gates
swift run dfsim replay Fixtures/replays/smoke.rec --assert-hashes
swift run dfsim determinism-check --threads 1,2,4
swift run dfsim bench --scenario 200-dwarves --ticks 10000
swift run dfsim ascii --tick 500 --z 12          # read game state with no GUI
```

`ascii` is how you *look at* the game. Use it. A change that "should work" and a
change you have watched produce the right tiles are different things.

## Determinism rules for parallel code

The job system is deterministic by construction, and it stays that way only if
you follow the pattern:

- Partition work into index ranges **before** dispatch. Never let a worker claim
  work dynamically in a way that affects results.
- Workers write to disjoint slots, or to a per-worker command buffer that is
  merged **in worker order** at the barrier.
- Thread completion order must never influence state. If you cannot explain why
  your system is order-independent, it is not.
- Any new parallel system must pass `determinism-check --threads 1,2,4`.

## Conventions

- Fixed-point units are named at the declaration (`/// temperature, 1/100 °U`).
  A bare `Int32` with no stated unit is a bug waiting to happen.
- Systems declare their read/write component sets. These are validated at
  startup in debug builds — a wrong declaration is a loud startup failure rather
  than a heisenbug three milestones later.
- Hot paths use `UnsafeMutableBufferPointer` and avoid bounds-checked subscripts.
  Do **not** reach for `-Ounchecked` to paper over this; fix the code.
- Tests are named for the spec they verify (`testSPEC_M3_PATHS_flowFieldMatchesBFS`).

## Working agreement

- **Specs precede code.** If there is no approved spec in `docs/specs/` for what
  you are about to build, stop and write one. See `docs/specs/TEMPLATE.md`.
- **Research precedes specs.** Mechanics research lands in `docs/reference/` with
  confidence tags and sources. Where our behavior deliberately differs from DF,
  or where DF's behavior is unknown, the spec says so explicitly with
  `[DIVERGENCE: <rule> because <reason>]`. Never invent a mechanic silently —
  a guess that goes unmarked becomes canon three milestones later.
- **Replay fixtures are contracts between agents.** If your change alters another
  module's golden hashes, that is a conversation with the owning agent, not a
  fixup commit that re-blesses the hashes.
- **Perf budgets are numbers.** Each spec states ms/tick at a stated scale, and
  `bench` fails the build when you exceed it.

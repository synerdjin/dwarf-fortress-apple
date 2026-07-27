# dwarf-fortress-apple Constitution

A Dwarf Fortress–class colony simulation with full simulation depth, native to
macOS on Apple Silicon. Swift 6, data-oriented ECS, Metal tilemap renderer.

This document is the **single source of truth** for the project's governing
principles. `CLAUDE.md` points here; it does not restate these rules, because
two copies of a rule diverge and whichever copy an agent happens to read wins.

Every principle below exists because a specific class of bug becomes
*undetectable* without it. This project is built by agents that cannot watch a
fortress for forty hours to notice the stockpiles have quietly corrupted.
Determinism and headless observability are therefore load-bearing engineering
requirements, not testing niceties. Violating a principle is a correctness bug,
not a style nitpick — reviewers reject on sight.

## Core Principles

### I. No floating point in simulation state (NON-NEGOTIABLE)

All sim math is integer or `Fixed` (Q16.16, in `DFCore`). Floats are permitted
only in `DFRender`, `DFUI`, and worldgen *intermediate* stages whose results are
quantized to integers before entering sim state.

*Rationale:* float results vary with instruction selection, vectorization and
evaluation order. Once a float lands in sim state, replay stops being bit-exact
and every regression test in the project quietly becomes a coin flip.

*Enforcement:* `Fixed` is the only fractional type `DFCore` exposes; a
`Float`/`Double` in a sim module is a review rejection.

### II. All randomness flows through a named `RNGStream`

Draw from a per-subsystem stream derived from the world seed:
`RNGStream(seed: worldSeed, .combat)`. Per-entity or per-chunk independence uses
sub-streams: `RNGStream(seed:, .worldgenStrata, sub: chunkIndex)`. Never
`Int.random`, never `SystemRandomNumberGenerator`, never a shared mutable global.

*Rationale:* separate streams mean adding a die roll to combat cannot shift the
sequence worldgen or moods observe. A shared stream makes every local change a
global change, and breaks every replay fixture at once.

*Enforcement:* `RNGDomain` raw values are frozen — renumbering invalidates every
saved world. Sub-streams are what let parallel and out-of-order generation
produce identical results.

### III. Sim state is mutated only by applying `Command` values from a queue

UI, input, and AI *produce* commands. The tick loop *consumes* them in
deterministic order. No code outside a system's tick function writes sim state.

*Rationale:* this single rule buys replay, save-scumming, undo, and future
networking. It is also what makes `dfsim replay --assert-hashes` a real
regression net rather than a smoke test.

### IV. Component types must be `BitwiseCopyable`

No `class`, `String`, `Array`, or any other reference or heap type inside
component data. Strings intern to `SymbolID: UInt32` via `StringTable`.
Components must additionally have **no interior padding**: padding bytes are
uninitialized and would feed garbage into buffer hashing.

*Rationale:* ARC traffic in a loop over 100k entities is the difference between
a playable fortress and a slideshow, and bitwise-copyable components make
serialization a bulk copy instead of a graph walk.

*Enforcement:* the `Component` protocol refines `BitwiseCopyable`, so violations
do not compile. Padding is asserted per-type in tests.

### V. Every module ships unit tests and a headless `dfsim` verb

If a subsystem can only be exercised by launching the app and looking at it, an
agent cannot verify it. Add the verb in the same change as the feature.

*Rationale:* an agent has no eyes. `dfsim ascii` is how the game is *looked at*;
`dfsim replay --assert-hashes` is how behaviour is held still. A change that
"should work" and a change observed producing the right tiles are different
things.

## Determinism Rules for Parallel Code

The job system is deterministic *by construction*, and stays that way only if
the pattern is followed:

- Partition work into contiguous, ordered index ranges **before** dispatch.
  Never let a worker claim work dynamically in a way that affects results.
- Workers write to disjoint slots, or to a per-worker scratch buffer merged
  **in partition order** at the barrier.
- Because partitions are contiguous and merged in order, results must be
  independent of partition count entirely. If a result changes when the worker
  count changes, the system is wrong — not the machine.
- Thread completion order must never influence state. If you cannot explain why
  your system is order-independent, it is not.
- Any new parallel system must pass `dfsim determinism-check --threads 1,2,4`.

Locks do not satisfy this. Locking makes results *safe*, not *reproducible* —
the order in which contending threads win is still arbitrary.

## Research and Divergence Discipline

- **Research precedes specs.** Mechanics research lands in `docs/reference/`
  with sources and access dates, distilled in our own words. Documentation and
  observed behaviour only: no decompilation of DF binaries, no copying DF's
  raws, text, art, or tilesets. All shipped content is original.
- **Confidence is tagged.** Every claim is `[CONFIRMED]`, `[COMMUNITY]`, or
  `[UNKNOWN]`. A spec may build on the first two and must make an explicit
  decision about the third.
- **Divergence is declared, not smuggled.** Where DF's behaviour is unknown, or
  where we deliberately differ (we will — determinism and parallelism force it),
  the spec records `[DIVERGENCE: <our rule> because <reason>]`.

*Rationale:* this prevents an agent guessing at an undocumented mechanic and a
later agent treating the guess as gospel. Three milestones on, the guess is
load-bearing and nobody remembers it was a guess.

## Quality Gates

- **Perf budgets are numbers.** Every spec states ms/tick at a stated scenario
  scale. `dfsim bench` fails the build when a budget is exceeded.
- **Replay fixtures are contracts between agents.** If a change alters another
  module's golden hashes, that is a conversation with the owning agent, not a
  fixup commit that re-blesses the hashes.
- **Declared component access is enforced.** Systems declare read/write sets;
  debug builds record actual storage accesses and trap on undeclared ones.
- **Tests are named for the spec they verify**
  (`SPEC-M3-PATHS: flow field matches BFS`), and the cited spec must exist.
- **Verification must never require Xcode.** Tests run as a plain executable
  (`swift run dftest`). An agent that cannot run the tests cannot do the work.
- **A guard that has never failed is unproven.** When adding a check whose whole
  value is catching a rare condition, break it deliberately once, confirm it
  fires, and say so in the commit message.

## Governance

- This constitution supersedes all other practice. Where `CLAUDE.md`, a spec, or
  a plan disagrees with it, this document wins and the other is amended.
- Amendments require a written rationale, the migration impact on existing
  replay fixtures and saved worlds, and explicit human approval.
- Milestone specs require human approval before implementation begins. Sub-specs
  within an approved milestone may proceed on reviewer sign-off.
- Compliance is checked at every merge. `Scripts/ci.sh` is the merge gate.

**Version**: 1.0.0 | **Ratified**: 2026-07-26 | **Last Amended**: 2026-07-26

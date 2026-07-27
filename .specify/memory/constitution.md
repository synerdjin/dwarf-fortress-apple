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

**The rule is about the processor, not just the type.** A value
enters sim state only from a compute unit whose numerics are reproducible *by
contract*. CPU integer and `Fixed` arithmetic qualify: the ISA guarantees the
result. The following do not, and may not produce sim state:

- GPU floating-point of any kind, and Metal's default fast-math.
- Any cross-lane or SIMD-group-width-dependent reduction, because threadgroup
  and SIMD widths differ across GPU generations.
- Core ML / Neural Engine inference. Core ML re-partitions layers across
  ANE/GPU/CPU based on model shape, OS version and thermal state, and offers no
  bit-exactness contract across any of them.

Integer GPU compute is not banned outright, but it is admissible only under the
conditions in *Determinism Rules for Parallel Code*, and the burden is on the
proposing spec.

*Rationale:* the invariant's purpose is a replay that reproduces bit-for-bit on
a machine that is not this one. A unit whose vendor does not promise identical
bits cannot be on the path to sim state, however fast it is. This clause exists
because "the Neural Engine is idle, use it for dwarf moods" is advice that
recurs, sounds like free performance, and would silently convert every replay
fixture in the repository into a coin flip.

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

Two consequences that are easy to get wrong once and impossible
to change later:

- **`SymbolID` assignment is deterministic sim state.** Either content-addressed
  (a hash of the UTF-8 bytes, collisions checked and resolved deterministically)
  or an append-only table that is itself serialized verbatim and hashed.
  First-seen-order interning bakes execution history into hashed components and
  is a review rejection.
- **Positional indices into `ListStorage` lists are not stable references.**
  Anything that cross-references a sub-entity — a wound naming a body part, an
  item naming a container slot — uses a per-entity monotonic sub-ID, not an
  index that shifts when an earlier element is removed.

### V. Every module ships unit tests and a headless `dfsim` verb

If a subsystem can only be exercised by launching the app and looking at it, an
agent cannot verify it. Add the verb in the same change as the feature.

*Rationale:* an agent has no eyes. `dfsim ascii` is how the game is *looked at*;
`dfsim replay --assert-hashes` is how behaviour is held still. A change that
"should work" and a change observed producing the right tiles are different
things.

### VI. Serialized state is sectioned and versioned

Every on-disk format — replay, save, fixture — is a sequence of sections, each
carrying a type tag, a layout version for that type, and a byte length. A reader
skips sections whose tag it does not recognise rather than rejecting the file.
Struct memory layout is never the schema unless a golden layout test asserts
that struct's exact size, stride and field offsets.

A save is a state snapshot plus a command tail. It is not a command log replayed
from tick zero.

*Rationale:* the replay container memcpys structs and guards them with a single
global version field that hard-rejects on mismatch, so adding one field to
`Command` invalidates every fixture in the repository with no upgrade path.
Worldgen makes replay-from-zero unviable as a load strategy besides: regenerating
a world is not a loading screen anyone waits through. This is the cheapest thing
in the project to fix now and among the most expensive to fix after M4 multiplies
the number of serialized types.

*Enforcement:* a golden layout test per serialized struct; a reader test
asserting an unknown section is skipped, not rejected. No new serialized format
may be added before this invariant is implemented.

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
- Any new parallel system must pass `dfsim determinism-check`.

Locks do not satisfy this. Locking makes results *safe*, not *reproducible* —
the order in which contending threads win is still arbitrary.

Three additions, each covering a case the rules above do not:

- **Stencil systems double-buffer.** A system that reads its neighbours reads a
  previous-tick buffer and writes a next-tick buffer. An in-place stencil is a
  review rejection: its result depends on whether a neighbour was visited
  before or after the tile reading it, which is exactly the partition boundary.
- **Partition-order merge is not conflict resolution.** Merging in partition
  order gives a *reproducible* answer when two partitions write the same slot,
  not the *serial* answer — it yields "last partition wins", which no serial
  pass produces. A system whose partitions can collide must either state a
  commutative, associative conflict rule (integer min, max, saturating add) or
  run serially over a sorted work list. Choosing between those is a spec
  decision, recorded in the spec, not a detail settled in code.
- **The determinism gate tests realistic and unrealistic decompositions.**
  `determinism-check` runs a thread set including 1, a prime, and a count
  exceeding any plausible host core count — currently `1,2,3,7,16,64`. Testing
  only `1,2,4` leaves the production path on a 10-core machine untested.

**GPU compute is admissible only under all of the following**,
and no system uses it today: integer arithmetic only, fast-math disabled, no
cross-lane or SIMD-width-dependent operations, conflict resolution restricted to
integer atomics that are commutative and associative, and a stated argument for
why the kernel's result is independent of threadgroup size and dispatch order.
Note the limit honestly: unlike CPU integer math, which the ISA guarantees, GPU
reproducibility across vendor driver and hardware generations can only be
*tested on the machines you have*. A spec proposing GPU sim work states which
GPU families it was verified on.

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

Four additions:

- **Skips are not passes.** Every skipped check is counted and reported, and the
  run declares how many skips it expects. A skip whose precondition is not
  explicitly expected on this host fails the build. A test harness that reports
  "passed" for a check it did not run is worse than one that has no check.
- **Derived state may affect cost, never results.** Caches, revision counters
  and memoised digests live outside the hash, and a cold-cache run must produce
  hashes identical to a warm-cache run. Any spec introducing a cache states how
  that is checked.
- **Every `SPEC-*` ID cited in code exists in `specs/`,** checked mechanically
  in `Scripts/ci.sh` rather than by reading.
- **Human approvals are recorded** in `docs/decisions/` with date, approver and
  scope. An unrecorded approval did not happen.

**Perf budgets state bytes touched per tick alongside ms/tick,**
at the stated scenario scale. On a unified-memory SoC the CPU and GPU share one
memory controller, so a ms/tick figure measured on one machine hides the ceiling
the architecture actually hits, and offloading a bandwidth-bound pass to the GPU
does not widen the pipe. A budget in bytes can also be checked against a design
before the code exists, which is when it is cheapest to act on.

## Scope of the access validator

Stated plainly so no one mistakes its reach for its ambition. Today
`validateAccess` compares the set of component *types* a system touched against
the union of its declared reads and writes. It does not distinguish reads from
writes, and it does not cover `MapStore` or the RNG streams — which is to say it
covers none of the tile state M3 will mutate.

Before the M3 spec freezes, declarations distinguish reads from writes and
extend to non-component resources, and the recorder must be safe to call from
inside a parallel body or must trap loudly when it is not. Until that lands,
this section is the honest statement of coverage and the constitution does not
imply more.

## Governance

- This constitution supersedes all other practice. Where `CLAUDE.md`, a spec, or
  a plan disagrees with it, this document wins and the other is amended.
- Amendments require a written rationale, the migration impact on existing
  replay fixtures and saved worlds, and explicit human approval.
- Milestone specs require human approval before implementation begins. Sub-specs
  within an approved milestone may proceed on reviewer sign-off.
- Compliance is checked at every merge. `Scripts/ci.sh` is the merge gate.

**Version**: 1.1.0 | **Ratified**: 2026-07-26 | **Last Amended**: 2026-07-27

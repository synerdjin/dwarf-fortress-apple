# Milestone Specification: M0 — Foundations

**ID**: `SPEC-M0` (areas: `SPEC-M0-CORE`, `SPEC-M0-ECS`, `SPEC-M0-MAP`,
`SPEC-M0-SIM`) | **Date**: 2026-07-26 | **Status**: Approved (retroactive) ·
**Milestone complete** 2026-07-26 · **Amended** 2026-07-27 (areas `SPEC-M0-MAP`
and `SPEC-M0-SIM` declared — see the amendment note below)

> **Written after implementation.** M0 was built directly from the approved
> architecture plan, before the Spec Kit pipeline existed — the pipeline is
> itself an M0 deliverable, which is the chicken-and-egg this milestone had to
> break. This document records what was built and pins the acceptance criteria
> the existing tests verify. It also resolves the dangling `SPEC-M0-CORE` and
> `SPEC-M0-ECS` references in test suite names.
>
> Every milestone from M1 onward runs the pipeline in the correct order:
> requirements frozen, then design, then code. M0 is the only exception and it
> is labelled as one rather than quietly presented as process-compliant.

> **Amendment, 2026-07-27** (P0 backlog item 1, `docs/review-2026-07-27.md`
> §5.1.7). The original header declared two areas while `MapStoreTests.swift`
> cited four: `SPEC-M0-MAP` and `SPEC-M0-SIM` were dangling IDs that no spec
> declared. The behaviour they name was always covered here — by SC-008
> (materialization), SC-010 and DR-001 (replay and hash stability), DR-002
> (partition independence) — but the requirement text was filed under areas
> that did not exist, so the traceability was real and unfollowable. This
> amendment declares the two areas and writes down the requirements the
> existing tests verify. It adds no new obligation: every FR below was already
> shipped and tested at M0 completion. `Scripts/ci.sh` now fails on a dangling
> ID, so this class of drift cannot recur silently.

## Consumer Scenarios & Testing *(mandatory)*

Every consumer in M0 is another subsystem. There is no player-facing behaviour
in this milestone and no user story is invented for it.

### Scenario 1 - Sim math without floats (Priority: P1)

**Consumer**: every simulation subsystem

**Scenario**: A subsystem needs fractional quantities (flow rates, skill
progress, wound severity) and gets a fractional type whose arithmetic is exact
and identical on every run.

**Why this priority**: Constitution I. Nothing downstream can be deterministic
if the arithmetic underneath is not.

**Independently verifiable by**: `swift run dftest Fixed`

### Scenario 2 - Independent randomness per subsystem (Priority: P1)

**Consumer**: worldgen, combat, moods, job selection

**Scenario**: A subsystem draws random numbers from a named stream. Adding a
draw in one subsystem does not shift the sequence any other subsystem observes.

**Why this priority**: Constitution II. Without it, every change is a global
change and all replay fixtures break at once.

**Independently verifiable by**: `swift run dftest RNG`

### Scenario 3 - Behaviour held still by hashing (Priority: P1)

**Consumer**: the replay harness, and every future regression test

**Scenario**: Simulation state folds into a 64-bit digest that is identical
across processes and runs, so a behavioural change surfaces as a divergence at
the exact tick it first mattered.

**Why this priority**: this is the instrument the whole verification strategy
rests on.

**Independently verifiable by**: `swift run dftest hashing`

### Scenario 4 - Parallelism that cannot change results (Priority: P1)

**Consumer**: every tick phase that scans more than a few thousand elements

**Scenario**: A system splits work across workers and gets byte-identical
results to running it on one worker — for any worker count.

**Why this priority**: the alternative is a fortress that desynchronises from
its own replay after an hour because two haulers were assigned in a different
order on a busy frame.

**Independently verifiable by**: `swift run dftest Job`

### Scenario 5 - Entities and components with enforced access (Priority: P1)

**Consumer**: all of `DFSim`

**Scenario**: Systems store plain-data components on entities, iterate them
linearly, declare which component types they read and write, and are stopped
when they touch something undeclared.

**Independently verifiable by**: `swift run dftest ECS`

### Scenario 6 - Tests that run without Xcode (Priority: P1)

**Consumer**: every agent working on this repo

**Scenario**: An agent runs the full test suite with only Command Line Tools
installed.

**Why this priority**: neither swift-testing nor XCTest ships with CLT, so
`swift test` cannot run at all without a full Xcode install. An agent that
cannot run the tests cannot do the work.

**Independently verifiable by**: `swift run dftest` on a machine with no Xcode.

### Edge Cases

- **Zero/one/max scale**: empty ranges are a no-op, not a crash; single-element
  ranges partition to one piece; partition counts exceeding element counts do
  not produce empty partitions.
- **Entity died earlier in the tick**: stale handles report not-alive rather
  than resolving to whoever recycled the slot. Modifying an absent component is
  a no-op, not a trap — "the target died this tick" is ordinary.
- **Applied twice**: destroying an entity twice reports already-dead rather than
  trapping.
- **Save/load**: `RNGStream` is a 16-byte `BitwiseCopyable` value, so stream
  position round-trips verbatim. Full save/load lands in M2.

## Requirements *(mandatory)*

### Functional Requirements — `SPEC-M0-CORE`

- **FR-001**: A Q16.16 fixed-point type MUST provide exact addition,
  subtraction, multiplication and division for values in range, computing
  products and quotients through a widened intermediate and trapping on
  overflow rather than wrapping.
- **FR-002**: Fixed-point MUST floor toward negative infinity, so that tile
  coordinate conversion does not make the origin two units wide.
- **FR-003**: Fractional constants MUST be constructible exactly from rationals
  (`Fixed(1, over: 3)`), never via a float literal.
- **FR-004**: Randomness MUST be drawn from streams selected by a named domain,
  with sub-streams available for per-entity and per-chunk independence.
- **FR-005**: Domain raw values MUST be frozen; bounded draws MUST be free of
  modulo bias.
- **FR-006**: A stream MUST support O(log n) jump-ahead agreeing exactly with
  drawing n times.
- **FR-007**: State hashing MUST be order-sensitive, length-prefixed on tails,
  and MUST NOT be process-seeded.
- **FR-008**: Spatial types MUST provide Chebyshev distance as the default
  movement metric, integer-only squared euclidean distance, and row-major
  ordering for deterministic iteration.
- **FR-009**: Region construction MUST normalise corners given in any order.
- **FR-010**: Parallel work MUST be partitioned into contiguous ordered ranges
  before dispatch, with per-worker scratch merged in partition order.
- **FR-011**: Worker counts MUST be derived from the P/E core split, with
  simulation work sized to performance cores.

### Functional Requirements — `SPEC-M0-ECS`

- **FR-020**: Entity handles MUST pack a slot index with a generation counter so
  that stale handles are detectable after slot reuse.
- **FR-021**: Slot recycling MUST follow a fixed policy (LIFO), since it
  determines the layout every component array inherits.
- **FR-022**: Component types MUST be `BitwiseCopyable` by type constraint, not
  by convention.
- **FR-023**: Component storage MUST keep values densely packed for linear
  iteration while offering O(1) random access, and MUST repair its index when
  removal moves an element.
- **FR-024**: Destroying an entity MUST strip every component it held, so a
  recycled slot never inherits a corpse's state.
- **FR-025**: Storage hashing MUST be independent of insertion and removal
  history for identical contents.
- **FR-026**: The tick scheduler MUST run systems in explicit phase order, with
  registration order breaking ties within a phase.
- **FR-027**: Systems MUST declare read/write component sets, and debug builds
  MUST trap when a system touches an undeclared type.

### Functional Requirements — `SPEC-M0-MAP`

*(Declared by the 2026-07-27 amendment; verified by `SPEC-M0-MAP` suites in
`MapStoreTests.swift` since M0 completion.)*

- **FR-030**: `Tile` MUST be exactly 8 bytes with no compiler-inserted padding,
  and its raw encodings MUST be frozen, since they are hashed and serialized.
- **FR-031**: The map MUST store blocks as flat 16×16×1 slabs, and a fresh map
  MUST hold no tile storage at all.
- **FR-032**: A block MUST materialize only on a write that breaks its
  uniformity, and MUST collapse back to uniform when it becomes uniform again.
  Writing the value a uniform block already holds MUST NOT materialize it.
- **FR-033**: Out-of-bounds reads MUST return solid wall rather than trapping,
  so callers near a map edge need no special case.
- **FR-034**: Map hashing MUST be independent of how a given map was built,
  MUST detect any single changed tile, and MUST be unaffected by which blocks
  happen to be materialized.
- **FR-035**: `Block.revision` MUST advance on changes that affect passability
  and MUST NOT advance on purely cosmetic ones.

### Functional Requirements — `SPEC-M0-SIM`

*(Declared by the 2026-07-27 amendment; verified by `SPEC-M0-SIM` suites in
`MapStoreTests.swift` since M0 completion.)*

- **FR-040**: A replay MUST round-trip through its binary form byte for byte,
  including the empty case, and MUST reject malformed input rather than
  misreading it.
- **FR-041**: The command queue MUST drain in submission order, and the
  recording MUST preserve that order with each command's tick.
- **FR-042**: `Fortress.stateHash` MUST cover every input to a future tick,
  including undrained commands. It MUST NOT cover the recording, which is
  present while recording a fixture and absent while replaying one.
- **FR-043**: Designated tiles MUST actually be excavated — a deterministic
  simulation that does nothing satisfies every other requirement here.

### Determinism Requirements

- **DR-001**: Identical command sequences MUST produce identical per-tick state
  hashes across repeated runs.
- **DR-002**: Parallel results MUST be independent of partition count entirely,
  not merely race-free.
- **DR-003**: Chunk-keyed generation MUST be independent of generation order, so
  worldgen can be parallelised in M7 without changing its output.
- **DR-004**: Component iteration order MAY depend on add/remove history (it
  does — removal is swap-with-last) but MUST be identical for identical
  histories. State hashing MUST sort by entity so the digest reflects what the
  simulation *is*, not how its arrays were laid out.

### Key Entities

- **Fixed**: a fractional quantity in sim state, 4 bytes, Q16.16.
- **RNGStream**: a named, seekable random sequence; part of saved state.
- **StateHasher**: the per-tick digest accumulator.
- **EntityID**: a revocable handle to a simulation entity.
- **World**: the container for all simulation state.
- **TickScheduler**: the ordered pipeline of systems.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `swift run dftest` passes with zero failures and requires no Xcode
  installation. *(Met: 82 tests.)*
- **SC-002**: A seeded RNG sequence is pinned by hard-coded golden values, so a
  refactor that perturbs it fails here rather than as mysterious hash mismatches
  elsewhere. *(Met.)*
- **SC-003**: State digests are pinned by hard-coded goldens, proving the hasher
  is not process-seeded. *(Met.)*
- **SC-004**: Parallel work produces identical output across partition counts
  1–128, including work that draws randomness. *(Met.)*
- **SC-005**: Ten repeated runs of the same parallel work produce one distinct
  digest. *(Met.)*
- **SC-006**: The undeclared-component-access guard has been observed to fire.
  *(Met: verified deliberately; see commit `0dee198`.)*
- **SC-007**: The parallel determinism tests have been observed to fail when
  merge order is broken. *(Met: verified deliberately; see commit `f8340c3`.)*
- **SC-008**: An unexcavated map holds zero tile storage; blocks materialize
  only on a write that breaks uniformity, and collapse back when they become
  uniform again. *(Met: 200 dwarves on a 144×144×16 map materialize 49 of 1296
  blocks, 98 KiB.)*
- **SC-009**: `dfsim ascii` shows the fortress being dug — designations become
  floor and dwarves appear at the working face. *(Met.)*
- **SC-010**: **DR-001 in full.** A recorded 10,000-tick command stream replays
  to an identical hash sequence at all 101 checkpoints, and the scenario
  produces identical final hashes across `--threads 1,2,4` (and 8).
  *(Met: `Fixtures/replays/smoke.rec`.)*
- **SC-011**: Both halves of the regression net have been observed to fail.
  Making one system's behaviour depend on its partition index made
  `determinism-check` report divergence at threads=2 and 4, and made
  `replay --assert-hashes` fail 100 of 101 checkpoints, naming tick 101 as the
  first divergence. *(Met: verified deliberately.)*

### Performance Criteria

No budget is *enforced* in M0 — it establishes correctness primitives. The
baseline is recorded so that later regressions are visible:

- 200 dwarves, 144×144×16 map: **0.10 ms/tick** release, about 1% of the 10 ms
  frame implied by DF's 1200 ticks/day at a 100 FPS cap.

This number is not impressive yet and should not be read as headroom: M0
simulates no temperature, no fluids, and no real pathfinding. First enforced
budgets land in M1 (frame time) and M3 (thermal ms/tick).

## Research Basis

- **Reference material**: none. M0 contains no Dwarf Fortress mechanics — it is
  infrastructure, and nothing in it depends on DF's observable behaviour.
- **`[UNKNOWN]` items**: none.
- **Declared divergences**: none.

## Out of Scope

Deferred deliberately, with the milestone that picks each up:

- Save/load → M2 · Metal renderer → M1 · Thermal simulation → M3 ·
  Raws → M4 · Fluids and pathfinding → M6

The map store, `dfsim` CLI and replay fixture were originally listed here as
"M0 remainder" and are now delivered — see SC-008 through SC-011.

## Assumptions

- macOS on Apple Silicon only; little-endian byte order is assumed by the
  hasher and pinned by fiat.
- Xcode will be installed before M1 (offline Metal compiler, Instruments), but
  no verification path may ever depend on it.
- Sparse-set storage is sufficient; archetype storage is deferred until
  profiling demands it, not adopted pre-emptively.

# Review Brief — dwarf-fortress-apple

**Prepared**: 2026-07-26, at commit `a3a0b1d`, branch `m1-metal-tilemap-renderer`.
**Prepared by**: the agent that wrote the code, which is a reason to distrust
parts of it. Sections marked **⚠ self-assessment** are where I think my own
judgment is least reliable.

**Ask**: an adversarial architecture and process review *before* more is built
on these foundations. The expensive-to-change decisions are all made and
implemented; what remains in the current milestone is a window and a click
handler, which changes no contract below.

---

## 1. What this is

A Dwarf Fortress–class colony simulation with full simulation depth, native to
macOS on Apple Silicon (M4). Swift 6, data-oriented ECS, Metal tilemap renderer.
Planned and implemented by AI agents.

The framing decision, from which everything else follows: **DF-class simulations
are not hard to write, they are hard to verify.** A million interacting entities
where a subtle ordering change silently corrupts a fortress forty hours in, and
an agent that cannot watch it happen. So determinism and headless observability
are treated as load-bearing engineering requirements rather than testing
hygiene. Bit-exact replay is the regression net; everything else bends to keep
it true.

**Is that framing right?** If it is wrong, or over-applied, most of the cost in
this repository is misspent. That is the first thing worth challenging.

---

## 2. Current state

| | |
|---|---|
| Commits | 9, all on the milestone branches |
| Source | ~4,800 lines across 6 modules, plus ~2,050 lines of tests |
| Tests | 131, passing in **both** debug and release |
| Gates | `Scripts/ci.sh`: build ×2, tests ×2, replay fixtures, determinism across partition counts, headless capture reproducibility, bench |
| Milestones | M0 complete; M1 phases 1–3 of 5 complete |

Module layout, dependencies strictly downward:

```
DFCore  (1006)  Fixed-point, RNG streams, state hashing, job system, spatial types
DFECS   (1004)  Entities, component storage, list storage, tick scheduler
DFSim   (1620)  Map, tiles, commands, replay, fortress, snapshot, tileset
DFRender (699)  Metal tilemap, glyph atlas, headless capture
DFTests (2054)  Tests as an executable, not a .testTarget
```

`DFUI` does not exist yet. When it does, it will deliberately **not** import
`DFECS`, so the UI is structurally incapable of reaching simulation state.

### What works, demonstrably

- 10,000-tick recorded command stream replays to an identical hash sequence at
  all 101 checkpoints
- Identical final hashes across 1, 2, 4 and 8 partitions
- Dwarves path to designated tiles and excavate them; `dfsim ascii` shows it
- `dfsim shot` renders headlessly; two captures of the same state are
  byte-identical; the GPU path agrees with the ASCII path on every compared tile
- 0.10 ms/tick at 200 dwarves (1% of the 10 ms frame budget) — **but see §6**

---

## 3. The five invariants (`.specify/memory/constitution.md`)

These govern everything. Each exists to make a specific bug class detectable.

1. **No floating point in simulation state.** Integer or Q16.16 `Fixed` only.
   Floats permitted in render/UI and in worldgen intermediates that quantize
   before entering state.
2. **All randomness through a named `RNGStream`.** Per-domain PCG streams from
   the world seed, plus sub-streams for per-entity/per-chunk independence.
3. **Sim state mutated only by `Command` values from a queue.**
4. **Components must be `BitwiseCopyable`**, with no interior padding.
5. **Every module ships unit tests and a headless `dfsim` verb.**

**Questions worth pressing:**

- Are these the right five? Invariant 4 already forced a workaround
  (`ListStorage`) the moment research surfaced that creature anatomy is
  variable-length and nested. **Is another cliff coming?** Candidates: save/load
  versioning, worldgen history with thousands of historical figures and their
  relationships, item stacks with contents.
- Invariant 1 was independently validated by research (DF itself stores
  temperature as 16-bit integers and explicitly does not use floating point).
  But is it over-applied? Worldgen erosion and climate would be far simpler in
  floats, and their output is quantized anyway.
- Invariant 3 has no enforcement yet beyond convention and the planned module
  graph. Should it have teeth earlier?

---

## 4. The load-bearing technical claims

Each of these is something later work assumes. If one is wrong, the cost is
large and grows.

### 4.1 Deterministic parallelism — **the single most important claim**

`DFCore/JobSystem.swift`. The argument: work is split into **contiguous,
ordered** index ranges *before* dispatch; workers write to disjoint slots or to
per-partition scratch; scratch merges **in partition order** after the barrier.
Because partitions are contiguous and merged in order, the merged sequence
equals what a single-threaded pass would produce — so results are independent of
partition count *entirely*, not merely race-free.

`dfsim determinism-check --threads 1,2,4` asserts exactly this, and tests cover
partition counts 1–128 including work that draws randomness.

**Press on:** is the argument airtight in general, or airtight only for the
patterns I happened to write? What happens when a system needs to read another
partition's output, or when work is data-dependent (pathfinding, flood fill,
fluid pressure)? M6's fluid pressure is already flagged as a path trace through
mutable state — inherently sequential. Does the framework have an answer, or
will it need a second mechanism?

### 4.2 History-independent hashing

Three places had the same trap and all three solve it the same way: the state
hash must not depend on *how* a state was reached.

- `ComponentStorage` hashes in entity order, not dense order (removal is
  swap-with-last, so dense order encodes history)
- `ListStorage` hashes live lists in entity order and never touches offsets,
  capacity slack or garbage — which is what makes compaction unable to perturb a
  hash
- `MapStore` canonicalizes uniformity (a materialized block whose tiles became
  equal collapses back) so two identical maps built differently hash identically

**Press on:** are there remaining places where history leaks into the digest?
The entity allocator's free list *is* hashed, deliberately — two worlds with
identical contents but different free lists will diverge on the next spawn, so
they are genuinely different states. Is that reasoning right?

### 4.3 The snapshot boundary

`DFSim/FrameSnapshot.swift`. The simulation publishes a frame snapshot at the
end of each tick; the renderer reads the newest. A mutex guards only the
published slot, never the snapshot build, so a slow build cannot stall the
renderer and display refresh cannot lengthen a tick.

An earlier version had the writer and reader indexing a shared `Array` at
distinct indices, on the reasoning that distinct indices cannot collide. That
was wrong — it races on the array's own storage and copy-on-write check — and it
crashed only in release.

**Press on:** is the current design actually free of that class of problem, or
has it moved? Is `NSLock` the right primitive here?

### 4.4 Map representation

16×16×**1** blocks (flat z-slabs, matching DF's own geometry, because most
systems work within a z-level) with palette compression: a uniform block stores
one tile value and no array. 200 dwarves digging a 144×144×16 map materialize 49
of 1296 blocks, 98 KiB.

**Press on:** does this hold at the real target (768×768 × ~65 z-levels) once
fluids and temperature touch large regions? Palette compression assumes most of
the map stays uniform — temperature diffusion could break that assumption
completely, and temperature is now the M3 milestone.

---

## 5. Research findings that changed the plan

A DF mechanics sweep (`docs/reference/`, confidence-tagged, sources recorded)
overturned four decisions after they were made:

1. **Blocks are 16×16×1, not cubes.** Corrected before implementation.
2. **Temperature, not pathfinding, is the dominant cost in DF** — disabling it
   reportedly doubles FPS, while pathfinding is explicitly characterised as *not*
   a major drain. The plan had this inverted. M3 and M6 were swapped: M3 is now
   thermal simulation and contaminants, M6 is fluids plus pathfinding.
3. **Creature anatomy is variable-length and nested**, which invariant 4 had no
   mechanism for. Produced `ListStorage`.
4. **1200 ticks/day at a 100 FPS cap** gives a 10 ms/tick budget — every perf
   number in the project previously had no denominator.

**Press on:** finding (2) rests substantially on one wiki page. It reordered the
milestone plan. Is that too much weight on thin evidence? Similarly, the
decision to keep items as ordinary ECS entities rests on a single sentence about
item cost being mediated through temperature scanning.

---

## 6. ⚠ Self-assessment: where I am least reliable

Presented plainly because a reviewer should know where to look hardest.

### The 0.10 ms/tick number is not headroom

It measures a simulation with no temperature, no fluids, no real pathfinding,
no items, no needs. It is a regression baseline, nothing more. I have tried to
say so everywhere it appears, but it is the kind of number that gets quoted out
of context later.

### KI-001 is unexplained and I got it wrong once

See `docs/known-issues.md`. A release-only crash in the render path. I stated a
root cause (a `MTLBuffer.contents()` lifetime hazard) with confidence and it was
**disproved** — `withExtendedLifetime`, which is strictly safer and the
documented fix for that exact hazard, makes it fail on every run where the
current arrangement passes. Also eliminated: uninitialized-memory UB in the
storage types (real, now fixed, but not this bug), AddressSanitizer, Metal
validation, and the visible throw sites.

**This is the best target for fresh eyes**, precisely because my hypotheses have
been eliminated one at a time and I am anchored.

### My process failures form a pattern, not three slips

Worth more scrutiny than the architecture, in my view:

1. **I skipped my own spec process twice.** `CLAUDE.md` told every agent to stop
   if there was no spec; `docs/specs/` was empty; tests cited `SPEC-M0-CORE`,
   which did not exist. Fixed retroactively and labelled as retroactive.
2. **I shipped a CI gate that manufactured false confidence.** The capture step
   was wrapped so that a crash printed "no GPU reachable — capture skipped" and
   then "All gates passed." It reported success while `dfsim shot` was broken.
3. **Debug/release divergence hid for two milestones** because only debug was
   routinely exercised. Release is now its own CI gate.

The through-line: I was checking that things *passed* rather than that the
checks *could fail*. The constitution now requires deliberately breaking a guard
once and confirming it fires, and I have done that for the job system's merge
order, the scheduler's undeclared-access trap, and `ListStorage` history
blindness. **Are the remaining guards proven, or merely green?**

### Decisions I may be confidently wrong about

- **Hand-rolled test harness** (`DFTesting`, 156 lines) instead of XCTest or
  swift-testing. Justified because neither ships with Command Line Tools and
  verification must not require Xcode. Xcode is now installed. Is the
  justification still worth the cost of a bespoke harness?
- **Renderer decoupled from the simulation tick**, a declared divergence from
  DF, which couples one tick to one frame.
- **Sparse-set ECS over archetypes.** Chosen for implementability and
  order-reasoning, with archetype migration deferred to profiling. Is that
  deferral realistic once systems query multiple components?
- **Frame metadata in PNG chunks rather than rendered text**, which let me ship
  14 glyphs instead of ~55. Convenient for me; is it right?
- **Hand-drawn glyphs** to sidestep font licensing entirely.

---

## 7. Specific questions I would most like answered

1. Is the determinism-by-partition-order argument sound in general, or only for
   the patterns written so far? What breaks it first?
2. Does invariant 4 (`BitwiseCopyable`) have another cliff coming, and if so,
   should it be amended now rather than worked around a second time?
3. KI-001: any hypothesis that survives the eliminations in
   `docs/known-issues.md`?
4. Is the milestone ordering right after the temperature/pathfinding swap? M3 is
   now thermal simulation, whose parallel decomposition is a stencil — is that
   the right thing to build third?
5. Is palette-compressed map storage viable once temperature touches everything?
6. What is missing entirely that will be expensive later? Save/load versioning
   and modding/raws are the two I would guess, but the point of asking is that I
   would not see my own blind spot.

---

## 8. Where to start reading

| Order | File | Why |
|---|---|---|
| 1 | `.specify/memory/constitution.md` | The five invariants, with rationale. Governs everything. |
| 2 | `docs/reference/performance-model.md` | What actually costs frames in DF, and the finding that reordered the plan. |
| 3 | `Sources/DFCore/JobSystem.swift` | The determinism argument. |
| 4 | `Sources/DFECS/ComponentStorage.swift` + `ListStorage.swift` | Storage design and history-independent hashing. |
| 5 | `Sources/DFSim/FrameSnapshot.swift` | The snapshot boundary. |
| 6 | `docs/known-issues.md` | KI-001, and how far the investigation got. |
| 7 | `Scripts/ci.sh` | What is actually gated — and whether the gates can fail. |

To run it:

```bash
Scripts/ci.sh
```
```bash
swift run dfsim ascii --scenario small-dig --tick 4000 --z 6
```
```bash
swift run dfsim shot --scenario small-dig --tick 4000 --width 64 --height 30 --out frame.png
```

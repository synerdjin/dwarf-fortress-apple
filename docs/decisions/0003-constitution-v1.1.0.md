# Decision 0003 — Constitution v1.1.0 amendments

**Date raised**: 2026-07-27
**Approver**: Djin (project owner)
**Status**: ⏳ **REQUESTED — awaiting owner approval. Not in force.**
**Proposed text**: `.specify/memory/constitution-v1.1.0-draft.md`
**Applies on approval by**: replacing `.specify/memory/constitution.md` with the
draft (minus its DRAFT banner and `[NEW v1.1.0]` markers) and setting this file's
status to Approved.

## Context

`docs/decisions/0002` approved working the P0 remediation batch first, then
returning with the constitution amendments "backed by evidence from having done
the work." The P0 batch is complete and merged (PR #3, `Scripts/ci.sh` green,
136 tests / 0 failures / 0 skips, 0.095 ms/tick). This is that return.

Decision 0002 also adopted **Invariant VI in principle**, deferring its exact
wording to this amendment. That wording is clause 1 below.

## What is being asked

Ratify v1.1.0. Nine clauses, grouped by what approving each one costs.

### Group A — codify what the P0 batch already built (no new work)

These describe mechanisms that exist and run on every merge. Approving them
turns current practice into a rule a future agent cannot quietly drop.

| Clause | Already enforced by |
|---|---|
| Determinism gate tests 1, a prime, and a count above host core count | `Scripts/ci.sh:94` — `--threads 1,2,3,7,16,64` |
| Skips are not passes | `DFTesting.swift:101,208` (`skip()`, `--max-skips`) + `ci.sh:60,66` |
| Every `SPEC-*` ID cited in code exists in `specs/` | `Scripts/ci.sh:37-46` |
| Human approvals are recorded in `docs/decisions/` | this directory, 0001–0003 |

### Group B — forward-looking rules that gate future work

Approving these costs nothing today and constrains M3/M4/M6 design. Each exists
because the review found the current primitives cannot express the thing safely.

1. **Invariant VI — serialized state is sectioned and versioned.** Adopted in
   principle by 0002; this is the wording. Bars any new serialized format until
   implemented.
2. **Stencil systems double-buffer**; in-place stencils are a review rejection.
   Directly gates M3 temperature.
3. **Partition-order merge is not conflict resolution.** "Last partition wins"
   is reproducible but is not the serial answer. Colliding systems state a
   commutative rule or run serially over a sorted list — decided in the spec.
   Directly gates M6 fluids.
4. **Derived state may affect cost, never results** — cold-cache and warm-cache
   runs must hash identically. Gates the M3 map-hash caching in backlog item 9.
5. **Invariant IV additions** — `SymbolID` must be content-addressed or an
   append-only serialized table (never first-seen-order); `ListStorage`
   positional indices are not stable references. Both must be settled before
   the first generated name and before anatomy, i.e. before M4.
6. **Access-validator scope stated honestly** — a new section saying plainly
   that the validator covers component *types* only, not read-vs-write, and
   covers neither `MapStore` nor the RNG streams. This clause *reduces* what the
   constitution claims. It is here because the document currently implies
   coverage of exactly the state M3 will mutate, and an agent who believes that
   will not add the checks M3 needs.

### Group C — two additions from this session, not from the review

Separable. Reject either without affecting Groups A and B.

7. **Invariant I extends to the processor, not just the type.** A value enters
   sim state only from a compute unit whose numerics are reproducible by
   contract. Explicitly excludes GPU float, Metal fast-math, SIMD-width-dependent
   reductions, and Core ML / Neural Engine inference. Admits integer GPU compute
   only under stated conditions, with the honesty note that GPU reproducibility
   across hardware generations can only be tested on machines you have.

   *Why now:* nothing in the codebase is at risk today. The clause is
   prophylactic. "The ANE is idle, run dwarf moods on it" is advice that recurs,
   arrives sounding like free performance, and would convert every replay
   fixture into a coin flip via a route Invariant I does not currently name —
   Core ML re-partitions layers across ANE/GPU/CPU by OS version and thermal
   state with no bit-exactness contract. Cheaper to foreclose than to re-argue.

8. **Perf budgets state bytes touched per tick alongside ms/tick.**

   *Why:* on a unified-memory SoC one memory controller serves CPU and GPU, so
   ms/tick on one machine hides the ceiling the architecture actually hits. Worked
   example at the researched extents (`map-and-time.md`): 768×768×65 ≈ 38.3M
   tiles, temperature as `Int16`, naive double-buffered full sweep ≈ 153 MB/tick
   ≈ **15 GB/s at 100 ticks/s — roughly 13% of an M4's total bandwidth for one
   system.** That number is checkable against a design before code exists, which
   is when it is cheapest to act on, and it is the number that makes the
   active-set design in `performance-model.md` obviously correct rather than
   merely preferred.

## Migration impact

Required by Governance. **None of the nine clauses is retroactive.**

- **Replay fixtures**: no change on approval. `Fixtures/replays/smoke.rec` stays
  valid and its hashes stay green.
- **Saved worlds**: none exist.
- **Code**: no change required on approval. Group A already complies; Groups B
  and C constrain work not yet written.
- **Deferred hash-affecting work these clauses mandate**: backlog item 9
  (temperature field split out of `Tile`) and the per-block cached map digest
  will both move golden hashes when implemented. Both follow the existing
  fixture-contract process — proposed change and justification recorded in
  `docs/state.md` before re-blessing, as was done for the pending-command hash
  term in the P0 batch.
- **One-way doors closed by approving**: Invariant VI blocks adding a new
  serialized format before the sectioned container exists. That is the intent —
  it is the cheapest moment in the project's life to pay this — but it does mean
  M4 cannot begin serializing worldgen output until VI is implemented.

## Recommendation

Approve Groups A and B as a unit; they are the review's findings and the
evidence 0002 asked for. Groups C's two clauses are genuinely optional and are
presented separately so they can be declined without stalling the rest.

## Owner decision

_Unfilled. Record approval, partial approval, or rejection here with date, then
apply the draft and update `docs/state.md`._

# Tasks: M1 — Seeing the Fortress

Ordered by dependency. Each task names how it is verified, per Constitution V.

## Phase 1 — The snapshot boundary (blocks everything)

- **T001** `FrameSnapshot` + instance record in `DFSim`. Layout asserted, no
  padding. *Verify:* `dftest` layout test.
- **T002** `FrameSnapshotRing` — triple buffer with atomic published index.
  *Verify:* concurrent read/write test showing a reader never observes a
  partially written buffer.
- **T003** `SnapshotSystem` in `.bookkeeping`, registered only when a renderer
  is attached; rebuilds only dirty blocks in view. *Verify:* headless state
  hashes identical with and without the system (DR-001).

## Phase 2 — Drawing

- **T004** Glyph atlas from a project-authored 8×8 bitmap font.
  *Verify:* atlas texture hash is stable; every map glyph is non-empty.
- **T005** `Tileset` — maps tile and creature state to glyph + colours.
  *Verify:* golden table test.
- **T006** Metal device, runtime shader compilation, tilemap pipeline.
  *Verify:* pipeline builds on a CLT-only toolchain.
- **T007** Instanced tilemap pass, one draw per layer, depth dimming.
  *Verify:* `shot` output.

## Phase 3 — Headless capture (the agent-facing requirement)

- **T008** Offscreen render target + pixel readback + PNG encode, with frame
  metadata embedded in the PNG rather than drawn as text.
  *Verify:* `dfsim shot` writes a valid PNG.
- **T009** `dfsim shot` verb. *Verify:* SC-002 — every tile `ascii` reports as
  floor appears as floor in the capture.
- **T010** Golden-image test with device/OS recorded. *Verify:* SC-003 —
  two captures byte-identical.

## Phase 4 — Window and input

- **T011** `DFUI` window + `CAMetalDisplayLink` drawing from the ring.
  *Verify:* app runs, shows the fortress advancing.
- **T012** Camera: pan, zoom, z-level. View actions only, never commands.
  *Verify:* state hash unchanged by camera movement.
- **T013** Click-to-designate → `Command`. Float→tile flooring isolated and
  tested. *Verify:* fractional pixel positions in one tile all yield the
  identical command.
- **T014** `ui-session.rec` fixture. *Verify:* SC-004 — replays with no
  divergence.

## Phase 5 — Gates

- **T015** `render-300x200` bench scenario (PC-001). **Not actually done —
  found 2026-07-27 while reviewing the CI split (docs/state.md): the
  `render-300x200` *scenario* exists and is used by `determinism-check` and by
  T016's `--with-snapshot` bench, but nothing calls into `TilemapRenderer`'s
  real Metal draw pass and times it. `--with-snapshot` measures CPU-side
  snapshot *publication* (PC-002's subject), not GPU frame time (PC-001's).
  PC-001 — "300×200 sustains refresh rate, < 8.3 ms/frame" — has never been
  measured, hosted or local. Needs a GPU-timed frame-render bench; local-only,
  since hosted runners have no Metal device to time in the first place.**
- **T016** Snapshot cost bench (PC-002).
- **T017** Wire into `Scripts/ci.sh`.

## Phase 4–5 status (2026-07-27)

T011–T017 implemented. Two things are **not** as the plan describes, both
recorded rather than quietly absorbed:

1. **The plan's snapshot Cost Control paragraph describes an optimization that
   does not exist.** It states the snapshot "rebuilds only blocks whose dirty
   flag is set, intersected with the visible region" and that "a paused
   fortress with a still camera rebuilds nothing". `buildSnapshot`
   (`Tileset.swift:126`) rebuilds every visible tile on every call, with no
   dirty-flag consultation anywhere.

2. **PC-002 therefore holds at one viewport and fails at another.** Measured on
   an Apple M4, 5 layers (`depthLayers + 1`), `--with-snapshot` against the
   same run without. Both viewports fit inside their map, so this is all real
   in-map work with nothing hidden behind a clamp:

   | viewport | total ms/tick | baseline | snapshot delta | PC-002 (< 1 ms) |
   |---|---|---|---|---|
   | 144×144 (200-dwarves) | 0.963 | 0.094 | 0.868 | passes |
   | 300×200 (render-300x200, PC-001's own scale) | 2.590 | 0.298 | 2.292 | **fails, 2.3×** |

   So a window at the size PC-001 names costs 2.3× what PC-002 permits. The two
   requirements are not jointly satisfiable with a full rebuild per tick.

   Two corrections to earlier figures, both found in review and both recorded
   because the first was reported before it was checked:
   - An earlier version of the bench clamped its camera to the map with an
     inline `min()`, on a comment claiming parity with `CameraController`.
     That claim is false — the controller clamps the camera's *origin* but
     never its *size* — so the gate was measuring a camera the shipped window
     never produces and excluding the overhang cost a real window pays. The
     clamp is gone; viewports are chosen to fit their map instead.
   - `SimulationHost` was allocating a fresh snapshot every tick rather than
     building into the ring's writer buffer, defeating both mechanisms that
     exist to avoid exactly that. Fixing it removed ~0.19 ms/tick at 300×200.
     It did **not** change the conclusion: 2.48 → 2.29 is still 2.3× over.

**Was not fixed here; fixed below.** The dirty-flag reuse could not be built on
the existing `Block.dirty`: review §4.3 establishes that flag is renderer-owned
and cannot be reused for this, so a correct fix needed the sim-owned dirty bits
of P1 backlog item 9. Both budgets were gated in `Scripts/ci.sh` as 3× tripwires
on the measurements above so the position could not silently worsen while item
9 was scheduled.

## Phase 4–5 resolution (2026-07-27, later same day)

**Owner decision: pull item 9 forward, scoped to the dirty-bit/snapshot-gating
slice only** (not the temperature-out-of-`Tile` split, not per-block cached
hash digests — both remain scheduled, un-hash-affecting M3 work).

`MapStore` gained a sim-owned, monotonic per-block `contentRevision`
(`MapStore.swift`), and `Tileset.swift` gained `SnapshotCache` plus a
`buildSnapshot(camera:tileset:into:cache:)` overload that skips recomputing any
slot whose block's revision is unchanged since the cache last saw it, and
invalidates the whole cache on a camera change. `SimulationHost` owns one and
passes it every tick — the exact path both PC-002 benches measure. Detail and
the full design rationale: plan.md's amended Cost Control paragraph.

Not hash-affecting: `contentRevision` is never combined into `Fortress.hash`,
and the un-cached `buildSnapshot(camera:tileset:into:)` overload (used by
`dfsim shot`, `RenderTests`, and every other existing caller) is untouched —
only `SimulationHost`'s call site changed.

First version checked the revision once per tile. That worked at 144×144 but
left 300×200 at a coin-flip margin against PC-002's 1.0 budget (0.93–1.02
ms/tick, one sample over 1.0 under real load) — a real 2.3x win, not a solid
fix. Block-chunking the check (once per 16-wide run of columns, aligned to the
block boundary in world-x, instead of once per column — plan.md's Cost Control
paragraph has the detail) cut it a further ~4-5x. Remeasured, same method as
above (Apple M4, `--with-snapshot` against the same run without, ten runs
each):

| viewport | total ms/tick | baseline | snapshot delta | PC-002 (< 1 ms) |
|---|---|---|---|---|
| 144×144 (200-dwarves) | ~0.17–0.23 | ~0.095 | **0.070–0.134** | passes, ~8-14x under |
| 300×200 (render-300x200, PC-001's own scale) | ~0.52 | ~0.30 | **0.214–0.218** | passes, ~4.6x under |

PC-001 and PC-002 are now jointly satisfiable with real headroom at both
scales, not merely at 144×144. `Scripts/ci.sh` gates both as 3× tripwires on
these numbers (0.5 / 0.8), pending the first hosted-runner reading on this
change — same interim-then-tighten convention the gates have used throughout
this file.

## Deviations from plan.md

- **FR-012 is satisfied by PNG metadata, not rendered text.** The plan assumed
  drawing tick/z/camera as on-screen text, which would need a full letter set in
  the font. Embedding the metadata in the PNG is machine-readable — strictly
  better for the agent consumer FR-012 exists to serve — and removes ~40 glyphs
  of hand-authored font data from the milestone. On-screen HUD text moves to M2
  with the rest of the UI chrome.

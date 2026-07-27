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

- **T015** `render-300x200` bench scenario (PC-001).
- **T016** Snapshot cost bench (PC-002).
- **T017** Wire into `Scripts/ci.sh`.

## Deviations from plan.md

- **FR-012 is satisfied by PNG metadata, not rendered text.** The plan assumed
  drawing tick/z/camera as on-screen text, which would need a full letter set in
  the font. Embedding the metadata in the PNG is machine-readable — strictly
  better for the agent consumer FR-012 exists to serve — and removes ~40 glyphs
  of hand-authored font data from the milestone. On-screen HUD text moves to M2
  with the rest of the UI chrome.

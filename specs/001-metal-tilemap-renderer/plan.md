# Implementation Plan: M1 — Seeing the Fortress

**Branch**: `m1-metal-tilemap-renderer` | **Date**: 2026-07-26 | **Spec**: [spec.md](./spec.md)

**Input**: `specs/001-metal-tilemap-renderer/spec.md` (Status: Clarified, all
`[NEEDS CLARIFICATION]` resolved)

## Summary

Draw the visible window of one z-level as a GPU-instanced grid of glyph quads,
fed by a **snapshot** the simulation publishes at the end of each tick. The
renderer never reads live simulation state, so it can draw at display refresh
while the simulation ticks independently, and it cannot perturb a replay.

The design's load-bearing choice is the snapshot boundary. Everything else —
instancing, atlas layout, shader compilation — is ordinary graphics work.

## Technical Context

**Language/Version**: Swift 6 (language mode v6), tools-version 6.0

**Primary Dependencies**: Metal, MetalKit, AppKit, ImageIO, CoreVideo. No
third-party packages. One bundled binary asset (bitmap font, see FR-013).

**Storage**: none. M1 persists nothing.

**Testing**: `swift run dftest`, plus `dfsim shot` golden-image comparison.

**Target Platform**: macOS 15+, Apple Silicon only

**Project Type**: new modules `DFRender` and `DFUI`, new executable
`dwarffortress`

**Performance Goals**: 300×200 tiles under 8.3 ms/frame (PC-001); snapshot
publication under 1 ms/tick at 200 dwarves (PC-002)

**Constraints**: captures byte-identical across runs (DR-003); simulation cost
unchanged whether or not a window is open (PC-002)

**Scale/Scope**: 60,000 visible tiles per layer, up to 4 layers drawn

## Constitution Check

*GATE: passed before design. Re-checked after — see the end of this document.*

| Principle | How this milestone complies |
|---|---|
| I. No floats in sim state | Floats appear only in `DFRender`/`DFUI`, which the constitution permits. The one place a float could leak into the simulation is mouse-position → tile-coordinate conversion; that conversion floors to `Int32` **before** constructing any `Command`, and the `Command` type has no floating-point field to put one in even by accident. |
| II. Named `RNGStream`s | The renderer draws no randomness. No stream is created in `DFRender` or `DFUI`. |
| III. Command-queue mutation | Input produces `Command` values only. `DFUI` has no reference to `World` or `MapStore` — it holds a read-only snapshot and a submit-only queue handle, so bypassing the queue is not merely discouraged but unavailable. |
| IV. `BitwiseCopyable` components | Adds no components. The instance record is `BitwiseCopyable` because it is uploaded to the GPU by bulk copy. |
| V. Tests + headless verb | Adds `dfsim shot`. Golden-image tests run in `dftest`. |

**No violations. Complexity Tracking is empty.**

## Determinism Contract

- **RNG streams drawn from**: none.

- **Iteration-order dependencies**: the snapshot builder walks the visible
  region in row-major order and creatures in `ComponentStorage` dense order.
  Neither affects simulation state — the snapshot is write-only output. Where
  two creatures occupy one tile, the **last** in dense order wins the glyph;
  that is a display artifact, documented, and does not feed back.

- **Parallel decomposition**: snapshot building partitions the visible region by
  **row range**, writing to disjoint slices of the instance buffer. No merge
  step is needed because outputs are indexed by tile position, not appended.

- **Why results are independent of worker count**: each output slot is written
  by exactly one partition, and its value is a pure function of the tile at that
  position plus the tileset. No partition reads another's output, and nothing is
  accumulated. The simulation is not written at all, so worker count cannot
  affect the state hash — DR-001 holds trivially by construction rather than by
  care.

- **Byte-identical captures (DR-003)** deserve their own argument, because "the
  GPU is deterministic" is not automatically true:
  - Vertex positions are computed from **integer** tile coordinates converted
    exactly to float. Values below 2^24 convert without rounding, and the map is
    far smaller than that, so no two runs can disagree about a vertex.
  - Nearest-neighbour sampling only. No mipmaps, no anisotropic filtering, no
    MSAA — each introduces implementation-defined behaviour.
  - No alpha blending in the tile pass; the background colour is written
    opaquely. Blending is order-dependent and the order is ours to lose.
  - Same device, same driver, same shader source ⇒ same rasterization. Captures
    are compared only against goldens produced on the same machine class, and
    the golden test records the device name so a mismatch is diagnosable rather
    than mysterious.

- **Fixed-point units**: none introduced. Camera zoom is a float (presentation
  only). Camera position is `Coord3` in tiles, integral, so panning cannot
  accumulate drift.

## Performance Budget

| Scenario | Scale | Budget | Measured by |
|---|---|---|---|
| `render-300x200` | 300×200 tiles, 4 layers, 200 dwarves | < 8.3 ms/frame | `dfsim bench --scenario render-300x200` |
| snapshot publication | 200 dwarves, 144×144×16 map | < 1 ms/tick | `dfsim bench --scenario 200-dwarves --with-snapshot` |
| `shot` capture | one frame | < 5 s wall clock | `dfsim shot` timing |

M0 measured 0.10 ms/tick for simulation alone. PC-002 allows snapshotting to
take up to ten times the entire current simulation cost, which sounds generous
and is: it is a ceiling to catch pathological work, not a target.

**Cost control**: the snapshot rebuilds only blocks whose dirty flag is set,
intersected with the visible region. `MapStore` already maintains per-block
dirty flags and clears them on demand — this is what they were for. A paused
fortress with a still camera rebuilds nothing.

## Tick Placement and Component Access

| System | Phase | Reads | Writes |
|---|---|---|---|
| `snapshot-publish` | `.bookkeeping` | `Position` | *(none)* |

`.bookkeeping` because it must observe the fully-settled tick — every other
phase has run, so what it captures is what the tick produced. It declares a read
of `Position` and writes no components; its output goes to the snapshot buffer,
which is not simulation state. The scheduler's undeclared-access guard covers
this automatically.

The system is registered **only when a renderer is attached**. A headless run
never pays for it, which is what makes "simulation cost is unchanged whether a
window is open" (PC-002) true rather than merely close.

## Replay Fixtures

- **Fixtures added**: `Fixtures/replays/ui-session.rec` — a recorded UI session
  (camera moves plus one designation) proving SC-004: input through the window
  replays identically to input through the CLI.
- **Fixtures whose golden hashes this changes**: **none.** If `smoke.rec`
  diverges, this milestone has broken Constitution III and the correct response
  is to fix the leak, not to re-record the fixture.

## Project Structure

### Documentation (this milestone)

```text
specs/001-metal-tilemap-renderer/
├── spec.md              # Requirements (frozen)
├── plan.md              # This file
├── data-model.md        # Snapshot and instance record layouts
├── contracts/           # DFRender and DFUI public surface
└── tasks.md             # /speckit-tasks output
```

### Source Code

```text
Sources/
├── DFCore/          (unchanged)
├── DFECS/           (unchanged)
├── DFSim/           + SnapshotSystem: publishes FrameSnapshot in .bookkeeping
├── DFRender/        NEW — Metal device, glyph atlas, tileset, tilemap pass,
│                    offscreen capture, PNG encoding
├── DFUI/            NEW — window, display link, input → Command mapping, camera
├── DFTests/         + renderer and snapshot tests
└── DFSimCLI/        + `shot` verb
Executables/
└── dwarffortress/   NEW — bare window, launched by `swift run dwarffortress`
Assets/
└── fonts/           NEW — bundled bitmap font + LICENSE (FR-013)
```

**Structure Decision**: `DFRender` depends on `DFSim` (to read a snapshot) and
`DFCore`; `DFUI` depends on `DFRender`. Neither is depended upon by anything
below, so the dependency direction stays downward and the simulation remains
buildable and testable with no graphics stack present.

Critically, **`DFUI` does not import `DFECS`**. It cannot reach `World`, so
Constitution III is enforced by the module graph rather than by discipline.

## Design

### The snapshot boundary

A `FrameSnapshot` is the visible window's worth of instance records plus the
metadata needed to label a frame (tick, z-level, camera). The simulation writes
it; the renderer reads it; neither blocks the other.

**Triple buffering, not locking.** Three snapshot buffers rotate: the simulation
writes into the one the renderer is not reading, and publishes by atomically
storing its index. The renderer atomically loads the newest published index and
reads that one. A lock would make the simulation's tick time depend on the
display's refresh, which PC-002 forbids.

Buffers are `MTLBuffer` with `.storageModeShared`. On Apple Silicon this is the
whole advantage of unified memory: the simulation writes instance data directly
into memory the GPU reads, with no staging copy and no upload step.

Sizing: 300×200 tiles × 4 layers × 12 bytes ≈ 2.9 MB per buffer, 8.6 MB for
three. Negligible against a 32 GB machine.

### Instance record

12 bytes, no padding, `BitwiseCopyable`:

| Field | Type | Meaning |
|---|---|---|
| `glyph` | `UInt16` | index into the atlas |
| `foreground` | `UInt8 × 4` | RGBA |
| `background` | `UInt8 × 4` | RGBA |
| `flags` | `UInt8` | depth-dimming level, occupancy |
| `reserved` | `UInt8` | explicit padding, always zero |

The layout is asserted in tests, as `Tile`'s is: a compiler-inserted hole would
put uninitialized bytes in a GPU buffer and make captures differ run to run.

### Drawing

One instanced draw per visible layer, deepest first. The vertex shader builds a
quad from `vertex_id` and the instance index — no vertex buffer, no index
buffer. The fragment shader samples the atlas with nearest filtering and mixes
foreground over background.

Depth cue (FR-005) is a per-layer dimming factor applied in the fragment shader,
derived from `flags`. A layer three levels down is drawn darker, not blurred:
blur would need filtering, and filtering endangers DR-003.

### Shader compilation

**Runtime compilation from embedded source is the primary path**, with a
precompiled `.metallib` used when present. That ordering is deliberate and
matters more than it looks:

The Metal toolchain is now installed, so precompiling is possible. But the
constitution says verification must never require Xcode, and a build that
*needs* the offline compiler breaks that the moment someone clones the repo onto
a machine with only Command Line Tools. Runtime compilation costs a few
milliseconds at startup and keeps the project buildable everywhere. The
`.metallib` path is an optimisation, and the two are tested to produce identical
captures.

### Headless capture

`dfsim shot` renders through the **same** pass into an offscreen texture, reads
the pixels back, and writes a PNG via ImageIO. Verified feasible: a plain CLI
process with no window created the device, compiled a shader at runtime,
rendered offscreen and read pixels back.

Sharing the pass with the windowed path is the point. A separate capture path
could drift from what players see, and SC-002 — `shot` agreeing with `ascii` —
would then be checking the wrong renderer.

### Input

`DFUI` classifies every event into exactly one of two kinds:

- **View actions** (pan, zoom, change z-level) mutate the `Camera` only. They
  are not commands, are not recorded, and cannot affect a replay.
- **Fortress actions** produce `Command` values. M1 implements exactly one —
  click a tile to toggle a dig designation — because the milestone's job is to
  prove the path, not to build the designation UI (that is M2).

Mouse position converts to a tile coordinate by flooring, in `DFUI`, before a
`Command` is built. This is the single point where a float could enter the
simulation, so it gets an explicit test that fractional pixel positions inside a
tile all produce the identical command.

### Threading

The simulation runs on a dedicated thread at a fixed tick rate. The renderer
draws from `CAMetalDisplayLink` callbacks at display refresh. They share only
the triple-buffered snapshot and an atomic index.

Swift 6 strict concurrency: `FrameSnapshotRing` is `@unchecked Sendable` with
the atomic-index argument documented at the type, in the same style as
`JobSystem`'s scratch buffer.

## Research Basis

- `docs/reference/map-and-time.md` — 16×16×1 blocks are z-slices, which is why
  a snapshot of one z-level touches contiguous blocks; the 10 ms frame budget
  PC-002 divides.
- `docs/reference/performance-model.md` — rendering is not a significant cost in
  DF. This plan spends its complexity budget on the snapshot boundary (a
  correctness concern) rather than on drawing throughput.
- `[DIVERGENCE: renderer decoupled from the simulation tick]` — carried from the
  spec; the triple-buffered snapshot is its implementation.

**`[UNKNOWN]` items**: none outstanding. All three spec clarifications resolved.

## Complexity Tracking

No constitutional violations. Table intentionally empty.

## Post-Design Constitution Re-Check

Re-evaluated after the design above:

- **I** — holds, and is now enforced structurally: `Command` has no float field,
  so a leak requires deliberately quantizing and lying about it.
- **II** — holds; no streams created.
- **III** — holds, and is *strengthened* by the module graph: `DFUI` cannot
  import `DFECS`, so it has no way to reach simulation state.
- **IV** — holds; the instance record is `BitwiseCopyable` with asserted layout.
- **V** — holds; `shot` added, golden-image tests in `dftest`.

**One risk to name rather than bury**: DR-003 (byte-identical captures) is the
least certain requirement here. The argument above is sound for a fixed device
and driver, but a macOS update that changes rasterization would break golden
images without breaking the renderer. Mitigation: golden tests record the device
name and OS version, and compare with a small per-channel tolerance **only if**
an exact match fails — reporting the difference either way, so a drift is
visible rather than silently absorbed. If that proves noisy in practice, the
fallback is to assert on `ascii`-equivalence (SC-002) and treat pixel goldens as
advisory.

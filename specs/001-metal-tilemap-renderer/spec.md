# Milestone Specification: M1 — Seeing the Fortress

**ID**: `SPEC-M1-VIEW` | **Date**: 2026-07-26 | **Status**: Approved (retroactive, covering phases 1–3 — see `docs/decisions/0001-retroactive-approvals-2026-07-27.md`)

> **Requirements only.** How this is built — Metal, instanced draws, buffer
> strategy, shader compilation — belongs in `plan.md` and is deliberately absent
> here. The approved plan already proposes a GPU tilemap and that proposal is
> probably right, but it is a design hypothesis; writing it into the
> requirements would mean a later change of approach silently moved the
> goalposts.

## Consumer Scenarios & Testing *(mandatory)*

Unlike M0, this milestone has a human consumer. It is the first point at which
the project is something a person can look at.

### Scenario 1 - A player sees their fortress (Priority: P1)

**Consumer**: player

**Scenario**: The application opens on a fortress and shows one z-level of the
map: terrain, excavated space, designations, and the dwarves standing on it.
The view updates as the simulation runs, without the player doing anything.

**Why this priority**: everything else in the milestone is navigation of this.

**Independently verifiable by**: running the app on the `small-dig` scenario
shows a room being excavated, matching what `dfsim ascii --tick N` prints for
the same tick and z-level.

### Scenario 2 - A player navigates the map (Priority: P1)

**Consumer**: player

**Scenario**: The player moves the view across the map, changes which z-level is
shown, and zooms in and out. Moving down a z-level shows what is beneath.

**Why this priority**: a fortress is three-dimensional and a single fixed view
of one level cannot convey it.

**Independently verifiable by**: a scripted input sequence drives the camera and
`dfsim shot` captures frames at known positions.

### Scenario 3 - A player perceives depth (Priority: P2)

**Consumer**: player

**Scenario**: Levels below the current one are visible but visually recessed, so
the player can tell an open shaft from a solid floor without changing level.

**Why this priority**: without it the map reads as flat and players cannot judge
what they are digging into. P2 because the milestone is still useful without it.

**Independently verifiable by**: `dfsim shot` of a scene with a known shaft
differs from the same scene with the shaft filled.

### Scenario 4 - An agent verifies rendering without a GUI (Priority: P1)

**Consumer**: every agent working on this repo

**Scenario**: An agent renders a frame to an image file from a headless
process — no window, no display session, no human present.

**Why this priority**: Constitution V. A renderer an agent cannot inspect is a
renderer an agent cannot change with confidence. This is the most important
requirement in the milestone for the project's ability to continue.

**Independently verifiable by**: `swift run dfsim shot --out frame.png` writes a
PNG whose content is stable across runs for a fixed scenario, tick and camera.

### Scenario 5 - A player chooses how the game looks (Priority: P2)

**Consumer**: player

**Scenario**: The player switches between a text-glyph presentation and a
graphical tile presentation without restarting.

**Why this priority**: the project committed to supporting both. P2 because one
of them shipping is enough to close the milestone.

**Independently verifiable by**: `dfsim shot --tileset <name>` produces visibly
different output for the same scene.

### Scenario 6 - Input becomes commands, never direct mutation (Priority: P1)

**Consumer**: the replay harness

**Scenario**: Every player action that changes the fortress produces `Command`
values on the queue. Recording a session and replaying it reproduces the same
fortress, bit for bit.

**Why this priority**: Constitution III. The moment the UI writes simulation
state directly, replay stops being a regression net and becomes decoration.

**Independently verifiable by**: a recorded UI session replays through
`dfsim replay --assert-hashes` with no divergence.

### Edge Cases

- **Zero/one/max scale**: a 1×1×1 map renders without special-casing; a 768×768
  map renders only the visible window, not the whole map.
- **Out of bounds**: a camera outside the map, or above the highest terrain,
  renders empty space rather than failing.
- **Target died this tick**: a creature destroyed between snapshot and draw must
  not leave a dangling reference or a ghost glyph.
- **Applied twice**: the same player action applied twice produces the same
  fortress as applying it once.
- **Window resize, zero-size window, display change**: rendering survives all
  three, including a window briefly sized to zero mid-resize.
- **No GPU available** (headless CI, remote session): frame capture must either
  work or fail with a clear message — never hang.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST display one z-level of the map, showing terrain
  type, material, designations and liquid presence distinguishably.
- **FR-002**: The system MUST display creatures at their current positions.
- **FR-003**: The system MUST update the display as the simulation advances,
  without player input.
- **FR-004**: The system MUST let the player pan, change z-level, and zoom.
- **FR-005**: The system MUST visually distinguish z-levels below the current
  one from the current one.
- **FR-006**: The system MUST render only the visible region, so cost scales
  with window size rather than map size.
- **FR-007**: The system MUST support at least two visual presentations (text
  glyphs and graphical tiles), switchable without restart.
- **FR-008**: The system MUST convert every player action that affects the
  fortress into `Command` values submitted to the queue.
- **FR-009**: The system MUST NOT write simulation state from rendering or input
  code.
- **FR-010**: The system MUST capture a frame to an image file from a headless
  process.
- **FR-011**: The renderer MUST NOT block the simulation tick, and the
  simulation MUST NOT block the display.
- **FR-012**: The system MUST show the current tick, z-level and camera
  position, so a captured frame is self-describing.
- **FR-013**: The repository MUST record the licence of every bundled font or
  tileset asset, and MUST NOT contain assets derived from Dwarf Fortress.

### Determinism Requirements

- **DR-001**: Rendering MUST NOT alter simulation state. A run with rendering
  and a headless run of the same commands MUST produce identical state hashes.
- **DR-002**: Floating point MAY be used in presentation code (Constitution I
  permits it in `DFRender`/`DFUI`) but MUST NOT flow back into simulation state.
  Any value derived from a float and submitted as a `Command` MUST be quantized
  to integers first.
- **DR-003**: A captured frame MUST be byte-identical across runs for a fixed
  scenario, tick, camera and tileset — otherwise `dfsim shot` cannot detect
  visual regressions.

### Key Entities

- **Camera**: what part of the world is shown — position, z-level, zoom.
- **Tileset**: the mapping from tile and creature state to visual appearance.
- **Frame snapshot**: the simulation state a frame is drawn from, decoupled from
  live state so drawing never reads a half-updated fortress.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A player launches the app from the command line, a window opens
  on the fortress, and they can watch dwarves excavate a room and navigate to
  the level below — with no code changes.
- **SC-002**: `dfsim shot` output agrees with `dfsim ascii` for the same
  scenario, tick and z-level: every tile the ASCII dump reports as floor appears
  as floor.
- **SC-003**: Two captures of the same scenario, tick, camera and tileset are
  byte-identical.
- **SC-004**: A recorded UI session replays with no hash divergence.
- **SC-005**: A headless capture succeeds with no display session attached, or
  fails within 5 seconds with an actionable message.

### Performance Criteria

- **PC-001**: A 300×200 tile viewport sustains the display's refresh rate on the
  target machine (120 Hz ProMotion → under 8.3 ms per frame), measured by
  `dfsim bench --scenario render-300x200`.
- **PC-002**: Rendering MUST NOT add more than **1 ms/tick** to simulation cost
  at 200 dwarves — 10% of the 10 ms frame budget established in M0. The
  simulation's own cost must not depend on whether a window is open.
- **PC-003**: Frame capture completes within 5 seconds, so CI can afford it on
  every change.

## Research Basis

- `docs/reference/map-and-time.md` — 16×16×1 block geometry (the renderer draws
  z-slices, which is part of why blocks are flat); 1200 ticks/day at a 100 FPS
  cap, giving the 10 ms frame budget PC-002 divides.
- `docs/reference/performance-model.md` — rendering is *not* identified as a
  significant cost in DF; the FPS problem is simulation-side. This milestone
  should not over-invest in rendering performance at M3's expense.

`[DIVERGENCE: the renderer runs decoupled from the simulation tick, drawing the
latest published snapshot at display refresh, whereas DF couples one tick to one
frame. Rendering at 120 Hz while simulating at 100 Hz is strictly better, and a
tile grid needs no interpolation to look right between ticks.]`

**`[UNKNOWN]` items**: none from DF. The open questions below are our own.

## Out of Scope

- Menus, unit lists, stock screens, job management UI → **M2 and later**
- Designation *tools* (drag-to-dig, zone painting) → **M2**, where digging
  becomes a player-driven activity. M1 proves the input→command path with a
  minimal action; it does not build the designation UI.
- Building placement and construction → M4
- Lighting, fog of war, visibility rules → later; M1 shows the whole level
- Sound, animation, particle effects → not planned
- Save/load → M2
- `.app` bundling, code signing, notarization → deferred until there is
  something worth distributing

## Assumptions

- The target display is ProMotion at 120 Hz; a 60 Hz display simply has a looser
  budget.
- One window, one fortress, one camera. Multiple views are not considered.
- Keyboard and mouse only; no gamepad or touch.
- Presentation code may use floating point freely, being downstream of every
  simulation decision.

## Open Questions

Resolve before `plan.md`. Each changes scope materially.

- ~~**Glyph source and licensing.**~~ **RESOLVED 2026-07-26.** A permissively
  licensed CP437-layout bitmap font is bundled in the repository, with its
  licence recorded alongside it. Chosen over rasterizing a system font because
  atlas contents must be identical across machines and OS versions — SC-003
  requires byte-identical captures, and an OS text stack offers no such
  guarantee. Dwarf Fortress's own tileset is not used and no part of it is
  copied.

  **Adds FR-013**: the repository MUST record the licence of any bundled font
  or tileset asset, and MUST NOT contain assets derived from Dwarf Fortress.

- ~~**Headless capture without a display session.**~~ **RESOLVED 2026-07-26 by
  experiment.** A plain command-line process with no window successfully created
  the system default device (Apple M4, unified memory), compiled a shader from
  source at runtime, rendered to an offscreen texture, and read the pixels back.
  Frame capture can therefore share the *real* rendering path rather than
  needing a separate software renderer — which removes the risk of the two
  disagreeing and undermining SC-002.

  Not yet verified: rendering over SSH with no window-server session at all. If
  CI ever runs that way, SC-005's "fails within 5 seconds with an actionable
  message" is the fallback, and it must be tested then rather than assumed now.

- ~~**How much application shell is in scope.**~~ **RESOLVED 2026-07-26.** M1
  delivers a bare window launched from the command line — no `.app` bundle, no
  signing, no notarization. Packaging is deferred until there is something worth
  distributing, and it is build tooling rather than rendering work.

  **SC-001 is amended accordingly**: "a player runs the app from the command
  line and a window opens on the fortress". Bundling moves to Out of Scope.

# Mechanics Reference Index

Research distilled in our own words from public documentation and community
analysis. Sources and access dates are recorded per document. No decompilation,
no copied raws, text, art or tilesets — see the constitution's *Research and
Divergence Discipline*.

Confidence tags used throughout:

- `[CONFIRMED]` — documented and corroborated
- `[COMMUNITY]` — widely reported, not independently verified
- `[UNKNOWN]` — undocumented; a spec depending on it must decide explicitly

## Documents

| File | Covers | Status |
|---|---|---|
| `map-and-time.md` | Map blocks, embark and z-level extents, tile scale, tick rate and calendar | Complete for architecture purposes |
| `performance-model.md` | What actually costs frames in DF, and what does not | Complete for architecture purposes |
| `simulation-mechanics.md` | Temperature, fluids, anatomy/wounds, jobs and labor | First pass |

## Coverage gaps

Deliberately not yet researched. Each is scheduled just-in-time for the
milestone that needs it, per the plan's "research done six milestones early is
research done twice":

| Area | Needed by |
|---|---|
| Needs, thoughts, personality, values | M5 |
| Strange moods and artifact generation | M5 |
| Combat resolution detail (momentum, materials, skill rolls) | M8 |
| Worldgen: terrain, climate, rivers, biomes | M7 |
| Historical simulation, legends, civilisations | M7 |
| Economy, caravans, trade, visitors | M9 |
| Sieges, justice, nobles | M8 |
| Materials and reaction matrix detail | M4 |

## Sweep of 2026-07-26

The first sweep targeted six decision questions that were already load-bearing
in committed code or the approved plan. Findings that contradict prior
decisions are summarised in `performance-model.md` and `map-and-time.md`, and
must be resolved in the relevant spec before the affected code is written.

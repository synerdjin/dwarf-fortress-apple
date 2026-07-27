# Map Structure and Time

**Researched**: 2026-07-26. Sources listed at the bottom.

## Map blocks

`[CONFIRMED]` DF divides the local map into blocks of **16 × 16 × 1** tiles —
flat, single-z-level slabs, not cubes. DFHack's Maps API states it directly:
blocks are 16 × 16 × 1 groups of local tiles.

`[CONFIRMED]` Many tile details are stored **at the block level** rather than
per tile, explicitly for space efficiency.

> **Impacts our design.** The approved plan specified 16 × 16 × 16 *cubic*
> chunks. DF's choice of flat slabs is not arbitrary: most systems operate
> within a z-level (fluid spreading, temperature exchange, pathing within a
> floor, and the renderer, which draws one z-slice at a time). A cubic chunk
> forces touching sixteen z-levels of data to read one, wasting cache lines on
> every per-level scan.
>
> Block-level storage of shared tile detail also independently validates the
> palette-compression idea in the plan — DF arrived at the same conclusion for
> the same reason.

## Extents

`[CONFIRMED]` Embark size ranges from 1×1 to 16×16 embark tiles. A 1×1 embark
is 48×48 local tiles, so the 16×16 maximum is **768 × 768** local tiles.

`[CONFIRMED]` Default worldgen produces roughly **50 z-levels of land** for an
embark with average elevation change, plus about **15 z-levels of empty sky**
above the highest terrain.

> **Impacts our design.** The plan assumed ~180 z-levels when sizing memory
> (768 × 768 × 180 ≈ 106M tiles). The default is closer to 65, though deep maps
> reaching caverns and the magma sea go further. Worst-case sizing should be
> driven by a stated maximum depth rather than an invented one.

`[CONFIRMED]` A tile represents roughly 2 m × 2 m horizontally and 3 m tall,
though physics calculations use 2.8 m for height. `[UNKNOWN]` whether the 2 m /
3 m figures are used anywhere mechanically or are purely flavour.

## Tile attributes

`[CONFIRMED]` Every tile carries Outside/Inside, Light/Dark, and Above
Ground/Subterranean flags. These are computed by casting a ray straight down
from the top of the map for each (x, y) column, marking tiles until the ray is
blocked.

> Useful: this is a per-column operation, embarrassingly parallel over (x, y),
> and its output is a pure function of the column contents — a good early
> candidate for the deterministic parallel-for pattern.

## Time

`[CONFIRMED]` Fortress mode runs **1200 ticks per day**, 28 days per month, 12
months per year — **403,200 ticks per year**. Adventurer mode uses a much finer
86,400 ticks per day, so the two modes do not share a tick scale.

`[CONFIRMED]` The default frame cap is **100 FPS**, and in DF one frame *is* one
simulation tick. At the cap, roughly one hour of real play is one in-game year.

> **Impacts our design.** This finally grounds every performance budget in the
> project. A 100 tick/second target means a **10 ms total budget per tick**. The
> plan's "under 2 ms/tick for pathfinding at 200 units" is therefore a claim on
> 20% of the entire frame — plausible, but it must be stated as a share of a
> known whole rather than floating free.
>
> `[DIVERGENCE: our renderer runs decoupled from the simulation tick, drawing
> the latest published snapshot at display refresh, because a fortress that
> renders at 120 Hz while simulating at 100 Hz is strictly better than DF's
> coupling, and grid rendering needs no interpolation.]`

## Sources

- DFHack Maps API documentation — block dimensions and block-level storage.
  https://docs.dfhack.org/en/stable/docs/api/Maps.html (accessed 2026-07-26)
- Dwarf Fortress Wiki, *Z-level* — z-level counts, embark tile scale.
  https://dwarffortresswiki.org/index.php/DF2014:Z-level (accessed 2026-07-26)
- Dwarf Fortress Wiki, *Tile* and *Tile attributes* — tile dimensions, the
  Outside/Light/Subterranean ray rules.
  https://dwarffortresswiki.org/index.php/DF2014:Tile (accessed 2026-07-26)
- Dwarf Fortress Wiki, *Time* — ticks per day, calendar structure.
  https://dwarffortresswiki.org/index.php/DF2014:Time (accessed 2026-07-26)
- Dwarf Fortress Wiki, *Frames per second* — frame cap, frame/tick equivalence.
  https://dwarffortresswiki.org/index.php/DF2014:Frames_per_second
  (accessed 2026-07-26)

# What Actually Costs Frames in Dwarf Fortress

**Researched**: 2026-07-26. Sources at the bottom.

This is the most consequential document from the first sweep, because it
contradicts a premise the approved plan was built on.

## The headline finding

`[COMMUNITY]` **Temperature is the dominant cost.** Disabling temperature
calculation is widely reported to give an FPS increase of 100% or more — a
doubling. The wiki additionally notes a bug causing "jitter" that forces
recalculation every frame, which inflates the cost beyond what the model itself
requires.

`[COMMUNITY]` **Pathfinding is explicitly described as *not* a major FPS drain.**
The wiki qualifies this: narrow corridors and bottlenecks cause the pathfinder
to repeatedly recompute routes for each dwarf and pet as paths clear, and
reducing the search area helps somewhat. So pathfinding cost is real but
topology-dependent and second-order.

`[COMMUNITY]` **Item count matters, but through temperature.** The wiki is
specific: stack *count* matters more than stack size because of the impact on
hauling, stockpiles and pathfinding — but "fewer items inside a fort means fewer
items checked for temperature, **which is the only major performance issue items
cause**."

`[COMMUNITY]` Commonly cited causes of "FPS death": excessive population,
contaminants (spatter, mud, blood), temperature, and item proliferation.

## Why this changes our plan

The approved plan states that DF's structural problem is "single-threaded
pathfinding and temperature collapsing FPS," and elevates pathfinding to its own
milestone (M3), calling it "the system most likely to decide whether this
succeeds," with the project's first hard budget attached.

The research inverts the ranking. Temperature is the doubling-level cost; item
proliferation is expensive *because* of temperature; pathfinding is real but
secondary. Three consequences:

1. **Temperature deserves the engineering investment currently allocated to
   pathfinding** — its own milestone, its own budget, and the parallelism work.
   It is also a far better fit for parallelism than pathfinding: a diffusion
   step over a tile lattice is a stencil operation, trivially partitioned into
   disjoint output ranges with double buffering, and needs no shared mutable
   state at all.
2. **Contaminants deserve a mention in the plan, which currently omits them
   entirely.** Spatter and mud spreading across tiles is named repeatedly as an
   FPS killer and we have no design for it.
3. **The item-storage question resolves in favour of the current design.** The
   worry was that six-figure item counts would make general ECS entities
   untenable and force specialised storage. The actual cost driver is
   temperature scanning over items, not job-site scanning over them — so items
   can remain ordinary entities, and the optimisation target is the temperature
   pass, which is exactly where a data-oriented layout and SIMD pay off.

## What this suggests structurally

`[UNKNOWN]` how DF decides *which* tiles and items need temperature updates each
tick. The "jitter bug forces recalculation every frame" remark implies the
intended design updates only where temperature is actually changing, and that
the bug defeats it.

That is the design worth pursuing regardless of what DF does:

> `[DIVERGENCE: temperature updates only propagate from an active set — tiles
> and items whose temperature changed last tick, plus their neighbours — rather
> than sweeping the whole map every tick, because the dominant cost in DF is
> recalculating a fortress that is overwhelmingly at equilibrium.]`

An equilibrium fortress should cost near zero. This must be designed in from
the start, not retrofitted, and the active set must be maintained
deterministically (sorted or index-ordered, never a hash set iteration).

## Sources

- Dwarf Fortress Wiki, *Maximizing framerate* — temperature disable impact,
  pathfinding characterisation, item/stack costs, hauling and stockpile advice.
  https://dwarffortresswiki.org/index.php/DF2014:Maximizing_framerate
  (accessed 2026-07-26)
- Dwarf Fortress Wiki, *Frames per second* — FPS death causes, frame/tick
  relationship. https://dwarffortresswiki.org/index.php/DF2014:Frames_per_second
  (accessed 2026-07-26)
- Dwarf Fortress Wiki, *Temperature* — the d_init temperature toggle.
  https://dwarffortresswiki.org/index.php/DF2014:Temperature
  (accessed 2026-07-26)

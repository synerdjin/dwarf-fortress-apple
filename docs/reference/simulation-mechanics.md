# Simulation Mechanics: Temperature, Fluids, Anatomy, Jobs

**Researched**: 2026-07-26. First pass — depth sufficient for architecture
decisions, not for implementing any of these systems. Sources at the bottom.

## Temperature

`[CONFIRMED]` Temperatures are stored as **16-bit unsigned integers**, range
0–65535 °U, internally limited to 60000 °U. The documentation is explicit that
**floating point values are not considered** — where fractions appear they are
truncated or rounded away.

> Strong independent validation of Constitution I. DF reached the same
> conclusion we did: a simulation this stateful cannot afford float drift. Our
> integer temperature is not a compromise for determinism's sake, it is what the
> reference implementation does.

`[CONFIRMED]` Heat transfer is per-tile and driven by each material's
`SPEC_HEAT`. The documented worked example: lignite (`SPEC_HEAT` 409) at 10015 °U
exposed to magma at 12000 °U warms by (12000 − 10015)/409 ≈ 4.85 °U in the first
tick, then progressively slower as the gap closes — i.e. exponential approach to
equilibrium.

`[UNKNOWN]` Whether the fractional part of that step is accumulated or
discarded. It matters: discarding every tick means a material with high
`SPEC_HEAT` next to a small gradient never changes temperature at all, which is
a real behavioural difference. **A spec depending on this must decide
explicitly.**

`[CONFIRMED]` `MELTING_POINT` serves as both melting and freezing point — they
coincide exactly, with no supercooling.

`[CONFIRMED]` Room temperature underground is around 10015 °U, magma around
12000 °U, giving a sense of the working scale.

## Fluids

`[CONFIRMED]` Liquids occupy **7 depth levels** per tile; 1 is a shallow puddle,
7 fills the tile.

`[CONFIRMED]` Liquids move by **three distinct rules**, and pressure is one of
them rather than a property of the liquid body:

1. **Gravity** — when the tile below holds less than 7/7.
2. **Diffusion** — adjacent tile levels average out.
3. **Pressure** — a separate mechanism, described below.

`[CONFIRMED]` Under pressure, fluid **traces a path through already-full tiles**
and can effectively *teleport* to a distant tile along that path. A pressure
trace may rise, but never above the z-level of the first 7/7 tile on the path.

`[CONFIRMED]` Water and magma differ fundamentally: magma has no pressure
behaviour and moves only by basic gravity and diffusion, while water under
pressure can move upward.

`[COMMUNITY]` A cistern-fed system delivers roughly 3 units per tick.

> **Design risk for M6.** The pressure rule is a *path trace through mutable
> state* — inherently sequential, and the classic case where parallel evaluation
> order changes results. Gravity and diffusion parallelise cleanly as a
> double-buffered stencil; pressure does not. The M6 plan must either run the
> pressure pass serially over a deterministically ordered work list, or design
> an order-independent formulation. This needs to be settled in the spec, not
> discovered during implementation.

## Anatomy and wounds

`[CONFIRMED]` Creatures have **no hit points**. They have a collection of body
parts (limbs, heads, torso), each with sub-parts and tissue layers: limbs have
skin, fat, muscle, tendons, bones, nerves and arteries; heads have brains, eyes,
noses, mouths, teeth, tongues; torsos have internal organs.

`[CONFIRMED]` Wound effects depend on which tissue layer is damaged — skin tears
bleed little and scar lightly; fat bleeds worse and scars severely with little
pain; muscle damage can disable a limb if a tendon, ligament or motor nerve is
severed; bone damage is the most painful and frequently causes unconsciousness.

`[CONFIRMED]` Tissues carry `PAIN_RECEPTORS` (most 5, bone 50).

`[CONFIRMED]` **Body plans vary by creature**, and procedurally generated
creatures (forgotten beasts, titans) may have entirely different anatomy,
including lacking vulnerabilities that normal creatures have.

> **Impacts our architecture, and this is the significant one.** Every creature
> carries a variable-length, *nested* structure: N body parts, each with M
> tissue layers, plus an open-ended list of wounds. Constitution IV forbids
> `Array` inside components, and the ECS as built has no mechanism for
> variable-length per-entity data at all.
>
> This is a genuine hole, not a tuning parameter, and it generalises well beyond
> anatomy — inventories, skills, relationships, memories and job queues are all
> variable-length per entity. `DFCore` needs an arena/side-table design: a
> component holding a `(offset, count)` range into a per-type pooled buffer,
> with the pool participating in state hashing and serialization. That is an
> addition to already-committed code.

## Jobs and labor

`[CONFIRMED]` Jobs are created by designations, zones, workshop tasks, and
manager work orders. Each job corresponds to a **labor**; an idle dwarf with
that labor enabled is assigned the job.

`[CONFIRMED]` Dwarves **refuse** disabled labors outright — this is not a
preference weighting.

`[CONFIRMED]` A dwarf's displayed profession derives from the highest-skilled
among their enabled labors.

`[CONFIRMED]` Hauling priorities are not uniform: trade good hauling outranks
all other hauling.

`[UNKNOWN]` The actual selection algorithm when several idle dwarves qualify for
one job, or when one dwarf qualifies for several. Distance, skill, and job
priority all plausibly participate. **M4 must decide this explicitly** — and
whatever it decides must be deterministic, which likely means a documented sort
rather than "nearest idle dwarf wins", since ties are common in practice.

## Sources

- Dwarf Fortress Wiki, *Temperature* — storage format, `SPEC_HEAT` worked
  example, melting/freezing coincidence.
  https://dwarffortresswiki.org/index.php/DF2014:Temperature (accessed 2026-07-26)
- Dwarf Fortress Wiki, *Pressure* and *Flow* — the three movement rules,
  pressure path tracing and its z-level ceiling, water/magma asymmetry.
  https://dwarffortresswiki.org/index.php/DF2014:Pressure (accessed 2026-07-26)
- Dwarf Fortress Wiki, *Combat*, *Wound*, *Anatomy* — body part and tissue
  model, wound effects by layer, procedural creature variation.
  https://dwarffortresswiki.org/index.php/DF2014:Wound (accessed 2026-07-26)
- Dwarf Fortress Wiki, *Labor* and *Hauling* — job/labor relationship,
  assignment behaviour, hauling priority.
  https://dwarffortresswiki.org/index.php/DF2014:Labor (accessed 2026-07-26)

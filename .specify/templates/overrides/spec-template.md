# Milestone Specification: [MILESTONE NAME]

**ID**: `SPEC-[M#]-[AREA]` | **Date**: [DATE] | **Status**: Draft | Approved | Superseded

**Note**: Filled in by `/speckit-specify`. This document states **what must be
true**, not how it is built. Data structures, algorithms and tick placement
belong in `plan.md`. Requirements outlive designs; keeping them apart is what
lets a design change without silently moving the goalposts.

Tests cite this ID (`SPEC-M3-PATHS: ...`). If code references an ID, this file
must exist — dangling spec references are a review rejection.

## Consumer Scenarios & Testing *(mandatory)*

The consumer of a milestone is sometimes a player and sometimes another
subsystem. Write whichever is honest. Do **not** invent a player narrative for
work whose only consumer is the pathfinder — fictional user stories produce
fictional acceptance criteria.

- **Player-facing milestone** → user stories ("A player designates a stairwell
  and dwarves dig it").
- **Subsystem-facing milestone** → consumer contracts ("The job system asks
  whether a tile is reachable and gets an answer in O(1) without allocating").

### Scenario 1 - [Brief Title] (Priority: P1)

**Consumer**: [player | named subsystem]

**Scenario**: [what happens, in observable terms]

**Why this priority**: [what is blocked without it]

**Independently verifiable by**: [the exact command, e.g.
`swift run dfsim ascii --tick 500 --z 12` showing a dug staircase]

### Scenario 2 - [Brief Title] (Priority: P2)

[Same shape.]

### Edge Cases

Cases this project keeps getting bitten by — answer each or say why it cannot
arise:

- What happens at zero, one, and maximum scale?
- What happens when the target entity died earlier in the same tick?
- What happens when the map region is unreachable or unloaded?
- What happens on save/load across this state?
- What happens when the same command is applied twice?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST [observable behaviour, no implementation detail]
- **FR-002**: System MUST [...]

Each requirement must be testable by a named command. A requirement no test can
fail is not a requirement.

### Determinism Requirements

Non-negotiable per Constitution I–III. State explicitly:

- **DR-001**: Given identical commands, this milestone MUST produce identical
  per-tick state hashes across runs and across `--threads 1,2,4`.
- **DR-002**: [any milestone-specific determinism obligation, e.g. "chunk
  generation MUST be independent of generation order"]

### Key Entities *(include if the milestone introduces sim state)*

- **[Entity]**: [what it represents and what it owns — not its Swift layout]

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: [Observable, technology-agnostic, with a number where one applies]
- **SC-002**: [...]

### Performance Criteria

- **PC-001**: [scenario] at [scale] completes within [ms/tick], measured by
  `dfsim bench --scenario [name]`

State the scale. "Fast enough" is not a criterion.

## Research Basis

- **Reference material**: [links into `docs/reference/`, with confidence tags]
- **`[UNKNOWN]` items**: [each unresolved DF behaviour this milestone depends
  on. Every one needs an explicit decision before the plan is approved.]
- **Declared divergences**: `[DIVERGENCE: <our rule> because <reason>]`

## Out of Scope

[What this milestone explicitly does not do, and which milestone picks it up.
The most useful section in the document — it is what stops scope creep being
mistaken for progress.]

## Assumptions

[Anything taken as given. If an assumption turns out false, this is the list
someone rereads to find out why the milestone went wrong.]

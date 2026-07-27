# Implementation Plan: [MILESTONE]

**Branch**: `[milestone-name]` | **Date**: [DATE] | **Spec**: [link]

**Input**: Milestone specification from `specs/[milestone]/spec.md`

**Note**: Filled in by `/speckit-plan`. This is the **design** half of the
milestone; requirements live in `spec.md` and are frozen before this is written.
If designing reveals that a requirement is wrong, amend the spec explicitly —
do not quietly design to a different target.

## Summary

[Primary requirement from the spec + the technical approach chosen.]

## Technical Context

**Language/Version**: Swift 6 (language mode v6), tools-version 6.0

**Primary Dependencies**: none beyond the platform. Adding a third-party
dependency requires justification here — hermetic offline builds are a project
property, not an accident.

**Storage**: [chunked binary saves / N/A]

**Testing**: `swift run dftest` (in-repo `DFTesting` harness — **not** XCTest or
swift-testing; neither ships with Command Line Tools)

**Target Platform**: macOS 15+, Apple Silicon only

**Project Type**: [DFCore / DFECS / DFSim / DFWorld / DFRaws / DFRender / DFUI]

**Performance Goals**: [ms/tick at a stated scale. A number, not an adjective.]

**Constraints**: [memory ceiling, latency budget, allocation limits]

**Scale/Scope**: [e.g. 200 dwarves, 3x3 embark, 180 z-levels]

## Constitution Check

*GATE: must pass before design begins. Re-check after design is complete.*

Answer each; "N/A" is acceptable with a reason, silence is not.

| Principle | How this milestone complies |
|---|---|
| I. No floats in sim state | [where fractional values arise and why `Fixed`/integer suffices] |
| II. Named `RNGStream`s | [which domains/sub-streams; or "draws no randomness"] |
| III. Command-queue mutation | [which commands this adds; who produces and consumes them] |
| IV. `BitwiseCopyable` components | [new component types; padding checked] |
| V. Tests + headless `dfsim` verb | [the verb this milestone adds] |

## Determinism Contract

*The section that exists because this project dies without it.*

- **RNG streams drawn from**, in draw order: [domain, sub-stream keying]
- **Iteration-order dependencies**: [what is iterated, and why the order is
  stable; if a set or dictionary is walked, say how it is sorted first]
- **Parallel decomposition**: [what is partitioned, what each worker writes to,
  what is merged and in what order]
- **Why results are independent of worker count**: [state the argument. If you
  cannot, the system is not deterministic yet.]
- **Fixed-point units**: [every quantity with its unit, e.g. "temperature,
  1/100 °U"]

## Performance Budget

| Scenario | Scale | Budget | Measured by |
|---|---|---|---|
| [name] | [200 dwarves, 3x3 embark] | [ms/tick] | `dfsim bench --scenario [name]` |

Budgets are enforced: `dfsim bench` fails the build when exceeded. A budget
that has never been measured is a guess — record the first measurement here.

## Tick Placement and Component Access

| System | Phase | Reads | Writes |
|---|---|---|---|
| [name] | [.movement] | [components] | [components] |

Declared access is enforced at runtime in debug builds. Over-declaring is
wasteful; under-declaring traps.

## Replay Fixtures

- **Fixtures added**: [path, what it exercises, tick count]
- **Fixtures whose golden hashes this changes**: [list, or "none"]

Changing another module's golden hashes is a conversation with the owning
agent, not a fixup commit.

## Project Structure

### Documentation (this milestone)

```text
specs/[milestone]/
├── spec.md              # Requirements (frozen before plan.md)
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── contracts/           # Public API surface other modules may rely on
└── tasks.md             # /speckit-tasks output
```

### Source Code

```text
Sources/
├── DFCore/       # fixed-point, RNG, hashing, job system, spatial types
├── DFECS/        # entities, component storage, tick scheduler
├── DFSim/        # map chunks, simulation subsystems, commands
├── DFTesting/    # test harness (no XCTest dependency)
├── DFTests/      # test executable
└── DFSimCLI/     # dfsim: replay, ascii, bench, determinism-check
```

**Structure Decision**: [which modules this milestone touches, and why the
dependency direction stays downward]

## Research Basis

- **Reference docs consulted**: [links into `docs/reference/`]
- **`[UNKNOWN]` items and their resolutions**: [each one, with the decision made]
- **Divergences declared**: `[DIVERGENCE: <rule> because <reason>]`

## Complexity Tracking

> Fill ONLY if the Constitution Check has violations that must be justified.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| | | |

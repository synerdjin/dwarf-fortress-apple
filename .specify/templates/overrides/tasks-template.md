# Tasks: [MILESTONE]

**Input**: Design documents from `specs/[milestone]/`
**Prerequisites**: plan.md (required — including Determinism Contract, Performance
Budget, Tick Placement), spec.md (required — FR/DR/SC/PC IDs)

**Note**: Filled in by `/speckit-tasks`. Tests are **mandatory** (constitution
Principle V) and precede the code they verify. Every FR and DR in the spec maps
to a test task below; an unmapped requirement is a generation failure.

## Requirement Coverage

| Spec ID | Verified by task | Test name |
|---|---|---|
| FR-001 | T0NN | `testSPEC_[M#]_[AREA]_...` |
| DR-001 | T0NN | replay/determinism gate |

## Phase 1: Setup

- [ ] T001 [Description with exact file path in Sources/<Module>/]

## Phase 2: Foundational (blocking prerequisites for all scenarios)

- [ ] T00N [e.g. new component types with padding/BitwiseCopyable assertion tasks,
      new RNG domains, new commands registered]

## Phase 3+: One phase per scenario, in priority order

### Scenario 1: [name] (P1)

**Goal**: [from spec]
**Independently verifiable by**: [exact command from spec, e.g.
`swift run dfsim ascii --tick 4000 --z 6`]

- [ ] T0NN [P] [US1] Test SPEC-[M#]-[AREA] [requirement] in Sources/DFTests/[File].swift
- [ ] T0NN [US1] [Implementation with file path]
- [ ] T0NN [US1] Register system with declared reads/writes (plan's Tick Placement row)

### Scenario 2: [name] (P2)

[Same shape.]

## Final Phase: Verification (never skipped, never merged into another phase)

- [ ] T0NN Run `Scripts/ci.sh`; paste failing output verbatim into the report if any
- [ ] T0NN Replay all fixtures: `swift run dfsim replay Fixtures/replays/*.rec --assert-hashes`;
      if this milestone legitimately changes another module's golden hashes, record
      the conversation per the constitution before re-blessing anything
- [ ] T0NN `swift run dfsim determinism-check` (the default thread set is the gate;
      narrowing it with `--threads` is a debugging aid, not a pass)
- [ ] T0NN `swift run dfsim bench --scenario [name]` against the plan's Performance
      Budget number
- [ ] T0NN Observe the behavior via `dfsim ascii` (or this milestone's verb) and
      state what was seen, not what should be there
- [ ] T0NN Record/refresh replay fixtures per the plan's Replay Fixtures section
- [ ] T0NN For each guard added this milestone: break it once, confirm it fires,
      note it in the commit message
- [ ] T0NN Update `docs/state.md` (milestone phase complete)

## Dependencies

[Scenario completion order; which phases block which.]

## Parallel Execution Examples

[Per scenario: which [P] tasks can run together and why their files are disjoint.]

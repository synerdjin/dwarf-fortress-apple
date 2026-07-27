# dwarf-fortress-apple

A Dwarf Fortress–class colony simulation with full simulation depth, native to
macOS on Apple Silicon. Swift 6, data-oriented ECS, Metal tilemap renderer.

## Read these first

1. **`.specify/memory/constitution.md`** — the five invariants and the
   determinism rules. This is the authoritative source and it supersedes
   everything else, including this file. It is deliberately not restated here:
   two copies of a rule diverge, and whichever copy an agent happens to read
   wins.
2. **`docs/state.md`** — where things stand right now: active milestone, branch,
   spec status, pending approvals, ownership. Update it before you stop working.
3. **`docs/decisions/`** — recorded human approvals. A spec is approved only if
   a decision file says so; an unrecorded approval did not happen.
4. **`specs/<milestone>/spec.md`** — what the milestone must do.
5. **`specs/<milestone>/plan.md`** — how it is built.

If there is no approved spec for what you are about to build, stop and write
one. Requirements are frozen in `spec.md` before design begins in `plan.md`;
if designing shows a requirement is wrong, amend the spec explicitly rather
than quietly designing to a different target.

## Spec-driven workflow

This project uses [Spec Kit](https://github.com/github/spec-kit). Per milestone:

| Step | Command | Produces |
|---|---|---|
| Principles | `/speckit-constitution` | `.specify/memory/constitution.md` (done; amend rarely) |
| Requirements | `/speckit-specify` | `specs/<milestone>/spec.md` |
| De-risk | `/speckit-clarify` | resolved `[NEEDS CLARIFICATION]` markers |
| Design | `/speckit-plan` | `specs/<milestone>/plan.md` |
| Breakdown | `/speckit-tasks` | `specs/<milestone>/tasks.md` |
| Consistency | `/speckit-analyze` | cross-artifact report |
| Build | `/speckit-implement` | code |

Templates are overridden in `.specify/templates/overrides/`. The plan override
carries the sections that actually catch bugs here — Determinism Contract,
Performance Budget, Tick Placement and Component Access, Replay Fixtures — so
filling the template honestly is most of the design review.

Research precedes specs and lands in `docs/reference/` with confidence tags.

## Verification

Never report work as done without running these. `Scripts/ci.sh` is the merge gate.

```bash
Scripts/ci.sh                                    # build + test + replays + bench gates
swift run dfsim replay Fixtures/replays/smoke.rec --assert-hashes
swift run dfsim determinism-check --threads 1,2,4
swift run dfsim bench --scenario 200-dwarves --ticks 10000
swift run dfsim ascii --tick 500 --z 12          # read game state with no GUI
```

`ascii` is how you *look at* the game. Use it. A change that "should work" and a
change you have watched produce the right tiles are different things.

## Determinism rules for parallel code

See the constitution's *Determinism Rules for Parallel Code*. The short version:
partition before dispatch, write to disjoint slots or per-worker scratch, merge
in partition order, and be able to explain why the result does not depend on
worker count. Locks do not satisfy this.

## Naming conventions

Three naming systems coexist; keep them consistent per milestone:

- Spec directory: `specs/NNN-<short-name>` (sequential, e.g. `001-metal-tilemap-renderer`)
- Git branch: `mN-<short-name>` (milestone number, e.g. `m1-metal-tilemap-renderer`)
- Spec ID: `SPEC-M<N>-<AREA>` (cited by tests; frozen once code references it)

## Conventions

- Fixed-point units are named at the declaration (`/// temperature, 1/100 °U`).
  A bare `Int32` with no stated unit is a bug waiting to happen.
- Systems declare their read/write component sets. These are validated at
  startup in debug builds — a wrong declaration is a loud startup failure rather
  than a heisenbug three milestones later.
- Hot paths use `UnsafeMutableBufferPointer` and avoid bounds-checked subscripts.
  Do **not** reach for `-Ounchecked` to paper over this; fix the code.
- Tests are named for the spec they verify (`testSPEC_M3_PATHS_flowFieldMatchesBFS`).

## Working agreement

The constitution governs; this is the day-to-day shape of it.

- **Specs precede code.** No approved spec, no implementation. See *Read these
  first*.
- **Replay fixtures are contracts between agents.** If your change alters
  another module's golden hashes, that is a conversation with the owning agent,
  not a fixup commit that re-blesses the hashes.
- **A guard that has never failed is unproven.** When you add a check whose
  whole value is catching a rare condition, break it deliberately once, confirm
  it fires, and say so in the commit message.
- **Report honestly.** If tests fail, say so with the output. If a step was
  skipped, say that. "Should work" is not a result.

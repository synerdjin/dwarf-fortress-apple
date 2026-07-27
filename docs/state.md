# Project state

**Purpose**: the first thing an agent reads at session start, and the last thing
it updates at session end. `.specify/feature.json` is a mutable global pointer
that can go stale — if it disagrees with this file or the git branch, stop and
reconcile. Keep this file under ~40 lines; it is a pointer board, not a journal.

## Now

| | |
|---|---|
| Active milestone | `specs/001-metal-tilemap-renderer` (SPEC-M1-VIEW) |
| Branch | `remediation/p0-batch`, off `main`. Awaiting PR/review. `m1-metal-tilemap-renderer` still exists remotely, fast-forwarded to `main`. |
| Spec status | Approved (retroactive) — `docs/decisions/0001-retroactive-approvals-2026-07-27.md`. M0 spec amended 2026-07-27 to declare `SPEC-M0-MAP`/`SPEC-M0-SIM`. |
| Last completed | Review remediation **P0 batch complete** (backlog items 1–7 + scaffolding patches). Before that: M1 phases 1–3, merged via PR #1. |
| Next | Constitution v1.1.0 approval — the P0 batch is now the evidence `docs/decisions/0002` required. Then M1 phases 4–5 (window, camera, click-to-designate). |
| Blocking issues | KI-001 (release-only crash, `docs/known-issues.md`) — fresh hypotheses in `docs/review-2026-07-27.md` §5.3, now P1 backlog item 13 |
| Remote | https://github.com/synerdjin/dwarf-fortress-apple. `main` protected: requires the `Scripts/ci.sh` check (enforced for admins too), no force-push/deletion. CI: `.github/workflows/ci.yml` runs `Scripts/ci.sh` with `CI_ALLOW_NO_GPU=1` — the hosted runners have no Metal device, so a green CI run proves less than a green local one and never covers DFRender. |

## Pending owner approvals

- Constitution amendments v1.1.0 (proposals in `docs/review-2026-07-27.md` §6) —
  returns for approval **after** the P0 batch, per `docs/decisions/0002`.
  Invariant VI (serialized-state versioning) already adopted in principle there.


## Open work queues

- Remediation backlog: `docs/review-2026-07-27.md` §7. **P0 (1–7) done.** P1
  (8–14) is next after the v1.1.0 amendments; items 8–12 gate the M3 spec freeze.
- Deviations from the backlog as written, both argued in their commits:
  item 3 unified rounding on truncate-toward-zero rather than floor (floor
  cannot satisfy the negation identity the item asks for); item 5 hashed the
  pending command queue rather than documenting the boundary.

## Ownership

Until distinct agents own distinct modules, the owner of record for every module
and fixture is "the agent currently holding the active milestone", and the
"conversation with the owning agent" rule (constitution, Quality Gates) is
satisfied by writing the proposed golden-hash change and its justification here
before re-blessing. When parallel agents exist, split this table.

| Artifact | Owner |
|---|---|
| DFCore, DFECS, DFSim, DFRender, DFTests | active-milestone agent |
| `Fixtures/replays/smoke.rec` | active-milestone agent |

### Golden-hash changes (newest first)

- **2026-07-27, `smoke.rec`, all 101 checkpoints.** `Fortress.hash` now folds the
  pending command queue (P0 backlog item 5). Undrained commands are
  future-affecting state: two fortresses alike in every other respect but
  holding different pending commands diverge on the next `step()`, and the old
  digest certified them equal. Adding the term shifts every hash in the stream
  (`tick 1: 7d62ae4f484e653e -> 41c89984fa50418b`); no behaviour changed, and no
  divergence predates the term. `recording` is deliberately excluded — it is
  absent during replay, so hashing it would make every replay disagree with the
  run it replays. Re-recorded with the same command that produced the original:
  `swift run -c release dfsim record --scenario small-dig --seed 1 --ticks 10000
  --hash-interval 100 --out Fixtures/replays/smoke.rec`.
  Sole owner of the fixture per the table above; recorded here before re-blessing.

## Session log (newest first, keep last ~5)

- 2026-07-27: **P0 remediation batch complete** on `remediation/p0-batch`, six
  commits, `Scripts/ci.sh` green (exit 0) end to end. Skills installed and
  `scaffolding-patches/` retired; `determinism-check` widened to
  `1,2,3,7,16,64`; `Fixed` rounding unified on truncate-toward-zero and the
  `rounded` wrapping add fixed; counted `skip()` + `--max-skips` so a skip can
  no longer read as a pass; pending commands hashed (**smoke.rec re-recorded**,
  see Golden-hash changes); five ci.sh gates closed. Every new guard was broken
  once and observed to fire — output quoted in each commit message. Next agent:
  the constitution v1.1.0 amendments are now unblocked and are the next thing
  the owner is waiting on.
- 2026-07-27: PR #1 merged into `main`. Local and remote `main` and
  `m1-metal-tilemap-renderer` are all fast-forwarded to the same commit
  (`72c4318`) -- no divergence, safe starting point for the next session.
  Next agent: read this file, then start the P0 batch (task queue has it
  broken into #11 install-patches through #16).
- 2026-07-27: Remote created by owner; PR #1 opened; GitHub Actions CI added
  (`.github/workflows/ci.yml`, mirrors `Scripts/ci.sh` verbatim) and passed on
  first run (0.18 ms/tick on the hosted runner, capture step legitimately
  soft-skipped -- no Metal device on that runner). Branch protection on `main`
  now requires the `Scripts/ci.sh` check, applies to admins, blocks
  force-push/deletion -- closes backlog item 7. Note: `origin/main` had been
  pushed pointing at the same commit as the feature branch (empty diff, no PR
  possible); fixed with an explicitly confirmed force-push back to the
  M0-complete commit, no commits lost.
- 2026-07-27: Remediation plan approved (`docs/decisions/0002`): P0 batch before
  amendments; Invariant VI adopted in principle. P0 queue: install patches, then
  backlog items 1–7. Nothing implemented yet.
- 2026-07-27: External review delivered (`docs/review-2026-07-27.md`,
  `docs/review-scaffolding-2026-07-27.md`); decisions 0001 recorded; skills
  patches staged; this file created.

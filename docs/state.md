# Project state

**Purpose**: the first thing an agent reads at session start, and the last thing
it updates at session end. `.specify/feature.json` is a mutable global pointer
that can go stale — if it disagrees with this file or the git branch, stop and
reconcile. Keep this file under ~40 lines; it is a pointer board, not a journal.

## Now

| | |
|---|---|
| Active milestone | `specs/001-metal-tilemap-renderer` (SPEC-M1-VIEW) |
| Branch | `main` (PR #1 merged; `m1-metal-tilemap-renderer` still exists remotely, fast-forwarded to match `main`, safe to branch from or delete) |
| Spec status | Approved (retroactive) — `docs/decisions/0001-retroactive-approvals-2026-07-27.md` |
| Last completed | M1 phases 1–3 (snapshot boundary, tilemap renderer, headless capture), merged to `main` via PR #1 |
| Next | Review remediation **P0 batch first** (`docs/decisions/0002`): install scaffolding patches, then backlog items 1–7 in `docs/review-2026-07-27.md` §7. Then constitution v1.1.0 approval. Then M1 phases 4–5 (window, camera, click-to-designate). |
| Blocking issues | KI-001 (release-only crash, `docs/known-issues.md`) — fresh hypotheses in `docs/review-2026-07-27.md` §5.3 |
| Remote | https://github.com/synerdjin/dwarf-fortress-apple. `main` protected: requires the `Scripts/ci.sh` check (enforced for admins too), no force-push/deletion. CI: `.github/workflows/ci.yml`, mirrors `Scripts/ci.sh` verbatim. |

## Pending owner approvals

- Constitution amendments v1.1.0 (proposals in `docs/review-2026-07-27.md` §6) —
  returns for approval **after** the P0 batch, per `docs/decisions/0002`.
  Invariant VI (serialized-state versioning) already adopted in principle there.


## Open work queues

- Remediation backlog: `docs/review-2026-07-27.md` §7 (P0 items first)
- Scaffolding patches awaiting install: `scaffolding-patches/README.md`

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

## Session log (newest first, keep last ~5)

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

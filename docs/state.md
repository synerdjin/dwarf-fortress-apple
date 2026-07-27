# Project state

**Purpose**: the first thing an agent reads at session start, and the last thing
it updates at session end. `.specify/feature.json` is a mutable global pointer
that can go stale — if it disagrees with this file or the git branch, stop and
reconcile. Keep this file under ~40 lines; it is a pointer board, not a journal.

## Now

| | |
|---|---|
| Active milestone | `specs/001-metal-tilemap-renderer` (SPEC-M1-VIEW) |
| Branch | `investigate/ki-001` (PR #5), off `main` after PR #4 merged. `m1-metal-tilemap-renderer` still exists remotely at the older `72c4318`. |
| Spec status | Approved (retroactive) — `docs/decisions/0001-retroactive-approvals-2026-07-27.md`. M0 spec amended 2026-07-27 to declare `SPEC-M0-MAP`/`SPEC-M0-SIM`. |
| Last completed | **Constitution v1.1.0 approved in full and in force** (`docs/decisions/0003`). Before that: KI-001 root-caused and mitigated (PR #5); review remediation P0 batch (PR #3). |
| Next | **M1 phases 4–5** (window, camera, click-to-designate) — nothing is blocked. Then P1 backlog items 8–12, which gate the M3 spec freeze, and which v1.1.0 now makes mandatory rather than advisory. |
| Blocking issues | **None.** KI-001 root-caused 2026-07-27 (Swift 6.3.3 leaves `MTLBuffer.contents()` in the arm64 `swifterror` register `x21` on a non-throwing path; caller misreads it as a throw). Mitigated, `docs/known-issues.md` rewritten. Residual: not yet filed upstream — needs a standalone reducer. |
| Remote | https://github.com/synerdjin/dwarf-fortress-apple. `main` protected: requires the `Scripts/ci.sh` check (enforced for admins too), no force-push/deletion. CI: `.github/workflows/ci.yml` runs `Scripts/ci.sh` with `CI_ALLOW_NO_GPU=1` — the hosted runners have no Metal device, so a green CI run proves less than a green local one and never covers DFRender. |

## Pending owner approvals

- **None.** Constitution v1.1.0 approved in full and applied 2026-07-27
  (`docs/decisions/0003`). Next approval gate is the M2 milestone spec.


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

- 2026-07-27: **Constitution v1.1.0 approved in full by the owner and applied.**
  All nine clauses, Groups A–C; `constitution.md` is v1.1.0 and the draft file
  is deleted so only one copy of the rules exists. Live consequences to respect
  from now on: **Invariant VI blocks any new serialized format until the
  sectioned container exists, so M4 worldgen serialization is gated**; stencils
  must double-buffer (M3); partition-order merge is not conflict resolution, so
  M6 fluids must state a commutative rule or run serially; `SymbolID` must be
  content-addressed or an append-only serialized table before the first
  generated name; perf budgets state bytes/tick alongside ms/tick; and
  Invariant I now bars GPU float and Core ML/ANE from producing sim state.

- 2026-07-27: **KI-001 root-caused and mitigated** (PR #5, `investigate/ki-001`).
  Swift 6.3.3 leaves `MTLBuffer.contents()` in `x21`, the arm64 `swifterror`
  register, on a path that never throws; the caller reads non-null `x21` as a
  thrown error and traps in `_swift_getClass`. Confirmed by direct register
  reads at the caller's error checks and by predicting, then measuring, that the
  bogus error pointer's mapped region scales with the instance buffer. The
  `rethrows` hypothesis from review §5.3 is **refuted** (arrangement C).
  `uploadInstances` is now non-throwing — the only change that survived the
  worst arrangement, 15/15 trapping to 0/15. Still a workaround, not a cure, and
  not yet filed upstream. The release-capture gate was observed firing.
- 2026-07-27: Constitution v1.1.0 drafted and submitted (`docs/decisions/0003`,
  draft text in `.specify/memory/constitution-v1.1.0-draft.md`); **nothing
  applied — the constitution remains v1.0.0 pending owner approval.** Baseline
  `Scripts/ci.sh` green on `main` before and after: 136 tests, 0 failures,
  0 skips, 0.095 ms/tick (0.9% of the 10 ms budget). Also reviewed a proposal to
  push simulation onto the GPU and Neural Engine; rejected for sim state and
  folded into the amendment as clause 7 rather than the roadmap — reasoning in
  0003 Group C. Only non-draft code/doc change: a 128-byte cache-line note in
  `CLAUDE.md` conventions. Next agent: if 0003 is still unapproved, do not wait
  on it — M1 phases 4–5 and KI-001 item 13 are independent.
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

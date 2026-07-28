# Project state

**Purpose**: the first thing an agent reads at session start, and the last thing
it updates at session end. `.specify/feature.json` is a mutable global pointer
that can go stale — if it disagrees with this file or the git branch, stop and
reconcile. Keep this file under ~40 lines; it is a pointer board, not a journal.

## Now

| | |
|---|---|
| Active milestone | `specs/001-metal-tilemap-renderer` (SPEC-M1-VIEW) |
| Branch | `m1-dirty-flag-snapshot`, off `m1-window-and-input` (merged to `main` as PR #8). Awaiting PR/review. `m1-metal-tilemap-renderer` (the branch named in this repo's PR-target convention) is stale, still at the pre-PR#8 commit — PRs #6 onward have actually targeted `main`; worth a decision on which name is authoritative before the next branch. |
| Spec status | Approved (retroactive) — `docs/decisions/0001-retroactive-approvals-2026-07-27.md`. M0 spec amended 2026-07-27 to declare `SPEC-M0-MAP`/`SPEC-M0-SIM`. |
| Last completed | **PC-001/PC-002 conflict resolved** (P1 backlog item 9, dirty-bit/snapshot-gating slice — see Session log). Before that: M1 phases 4–5 (T011–T017); constitution v1.1.0 in force; KI-001 root-caused. |
| Next | **P1 backlog items 8, 10–12** (item 9 done, this slice of it), which gate the M3 spec freeze and which v1.1.0 makes mandatory rather than advisory. Item 9's other half — temperature split out of `Tile`, per-block cached hash digests — remains scheduled, deliberately deferred (see Session log). |
| Blocking issues | **None.** KI-001 root-caused 2026-07-27 (Swift 6.3.3 leaves `MTLBuffer.contents()` in the arm64 `swifterror` register `x21` on a non-throwing path; caller misreads it as a throw). Mitigated, `docs/known-issues.md` rewritten. Residual: not yet filed upstream — needs a standalone reducer. |
| Remote | https://github.com/synerdjin/dwarf-fortress-apple. `main` protected: requires the `Scripts/ci.sh` check (enforced for admins too), no force-push/deletion. CI: `.github/workflows/ci.yml` runs `Scripts/ci.sh` with `CI_ALLOW_NO_GPU=1` — the hosted runners have no Metal device, so a green CI run proves less than a green local one and never covers DFRender. **No hosted-runner reading yet for the snapshot-cache fix** — this branch's own CI run will be the first; `Scripts/ci.sh`'s two new gates are interim 3×-local tripwires (0.5 / 0.8 ms/tick) pending it. |

## Pending owner approvals

- **None.** Constitution v1.1.0 approved in full and applied 2026-07-27
  (`docs/decisions/0003`). Next approval gate is the M2 milestone spec.


## Open work queues

- Remediation backlog: `docs/review-2026-07-27.md` §7. **P0 (1–7) done. Item 9
  done (dirty-bit/snapshot-gating slice only — see Session log).** Items 8,
  10–12 remain and gate the M3 spec freeze. Item 9's temperature-split and
  hash-digest-caching half is also still open, deferred deliberately.
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

- 2026-07-27 (later session): **PC-001/PC-002 conflict resolved** — owner chose
  "pull item 9 forward," scoped to just the dirty-bit/snapshot-gating slice
  (temperature split and per-block hash-digest caching stay deferred, un-hash-
  affecting M3 work; this change touches no golden hash at all).
  `MapStore` gained a sim-owned, monotonic per-block `contentRevision`
  (superset of the existing passability-only `revision`); `Tileset.swift`
  gained `SnapshotCache` and a cached `buildSnapshot` overload that skips
  recomputing a slot when its block's revision is unchanged, checked once per
  16-wide block-aligned column run rather than once per tile — the chunking
  turned out to matter more than the cache itself once measured (see below).
  `SimulationHost` is the only caller that uses it; every other caller
  (`dfsim shot`, `RenderTests`, the plain `buildSnapshot`/`snapshot(camera:)`)
  is byte-for-byte unchanged. New test in `UITests.swift` compares the cached
  path against an uncached reference fortress at six tick checkpoints spanning
  designation, active digging, and completed digging, plus a camera pan
  mid-run; two new `MapStoreTests` assert the revision bumps on *any* change
  (not just passability, unlike `revision`) and is excluded from `stateHash`.
  All three broken once (`contentRevision &+= 1` commented out) and confirmed
  to fail before being restored.

  Measured in two stages, Apple M4, ten runs each, `--with-snapshot` delta:
  per-tile revision check landed at 0.93–1.02 ms/tick at 300×200 — a real 2.3x
  win over the pre-fix 2.29–2.4, but a coin-flip margin against PC-002's 1.0
  budget (one sample read over it inside a full `ci.sh` run). Block-chunking
  the same check cut it a further ~4-5x: **0.070–0.134 ms/tick at 144×144,
  0.214–0.218 at 300×200** — both comfortably under budget now, PC-001's own
  viewport included. Detail: `specs/001-metal-tilemap-renderer/plan.md`'s
  amended Cost Control paragraph and `tasks.md`'s Phase 4–5 resolution section.
  `Scripts/ci.sh`'s two snapshot gates are retightened to 0.5/0.8 ms/tick (3×
  local, interim pending this branch's first hosted CI run).

- 2026-07-27: **M1 phases 4–5 complete** (T011–T017). New `DFUI` target that
  deliberately cannot import `DFECS`, so Constitution III is enforced by the
  module graph; new `dwarffortress` window executable, the only target linking
  AppKit. Instance buffers now rotate per in-flight frame (review §5.2), with
  the caller contract stated and a test that breaks if any slot is unfilled.
  `dfsim ui-session` records a scripted-input fixture; it replays 20/20.
  **Two things the next agent must not rediscover the hard way:** the plan's
  snapshot Cost Control paragraph describes a dirty-flag optimization that was
  never implemented, and as a result PC-001 and PC-002 are not jointly
  satisfiable *(resolved in the entry above this one)*. **Also unverified: nobody has
  looked at the window.** It runs for minutes without error and its threads
  behave, but a bare executable has no bundle for screenshot tooling and
  `screencapture` lacked permission, so NSEvent translation and CAMetalLayer
  presentation are untested by anything. `swift run dwarffortress` to look.

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

  *(Older entries — P0 remediation batch, PR #1 merge, remote setup, initial
  review — trimmed per this section's own ~5-entry convention. See git log
  and `docs/decisions/` for that history.)*

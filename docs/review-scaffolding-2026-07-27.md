# Scaffolding Review — agent workflow and instructions

**Date**: 2026-07-27. Companion to `docs/review-2026-07-27.md` (architecture/process).
**Scope**: CLAUDE.md, constitution, `.specify/` (templates, overrides, scripts,
workflow), `.claude/skills/speckit-*` (the 10 skills agents actually follow).
Reading review; nothing executed.

---

## 1. Headline finding

**The project's discipline lives in the constitution, CLAUDE.md, and two excellent
template overrides — but the ten skills that actually steer an agent through a
milestone are untouched stock spec-kit.** All ten carry `author: "github-spec-kit"`;
a grep of `.claude/` for `ci.sh`, `dfsim`, `replay`, `determinism`, or `approval`
finds essentially nothing. The instructions with the most in-context authority at
implementation time have never heard of the merge gate, the replay net, the approval
requirement, or `docs/decisions/`.

Worse, in two places the stock skills **actively instruct agents to undo the
project's customizations**:

- `speckit-specify/SKILL.md:159-169, 337-342` requires specs to be
  "technology-agnostic", free of "implementation details", written for
  "non-technical stakeholders", and lists concrete perf commands as bad examples —
  while the project's own spec override *requires* "the exact command, e.g.
  `swift run dfsim ascii --tick 500 --z 12`" and `dfsim bench` in every performance
  criterion. A compliant agent will delete exactly the sections the project depends on.
- `speckit-tasks/SKILL.md:145` says "Tests are OPTIONAL — only generate test tasks if
  explicitly requested", directly contradicting constitution Principle V.

This explains the recurring failure pattern the first review found ("implementation
ran ahead of recorded approval", "checks that pass without being able to fail"): the
agents were following instructions in which those failures are not failures.

## 2. Specific gaps, with evidence

1. **The approval gate exists only in prose.** No skill reads the spec's `Status:`
   field; no skill knows `docs/decisions/` exists; CLAUDE.md doesn't mention it
   either. `speckit-implement`'s only gate (SKILL.md:62-91) counts checkboxes in
   checklists *the same agent generated and self-graded*. `workflow.yml` has
   approve/reject gates but only fires under the `specify workflow` runner (not the
   normal skill-invocation path), has no gate between tasks and implement, and
   records approvals nowhere.
2. **`speckit-implement` never runs the gates.** Its verification step is the generic
   "validate that tests pass" (SKILL.md:177); ci.sh, replay hashes,
   determinism-check, bench, and `dfsim ascii` observation appear nowhere. Its
   completion step has no honest-failure-reporting requirement. Meanwhile it spends
   40 lines (SKILL.md:102-144) on `.eslintignore`/Docker/Terraform patterns for a
   hermetic Swift repo.
3. **The spec template override loads only by luck.** The plan override is wired
   through `setup-plan.sh` → `resolve_template` (overrides win). But `speckit-specify`
   never invokes a script — it describes template resolution in prose (SKILL.md:96-99),
   so an agent that copies `.specify/templates/spec-template.md` gets a spec with no
   Determinism Requirements, no SPEC-ID, no Status field. **There is no tasks-template
   override at all** — tasks.md, the artifact implement actually executes, is generated
   from the stock web-app template (`backend/src/`, `ios/src/` path conventions) and is
   the only artifact of the three with no project DNA.
4. **No session continuity or multi-agent coordination artifact.** The constitution's
   "conversation with the owning agent" rule has no ownership registry — no addressee.
   `.specify/feature.json` is a single global mutable pointer (`common.sh:180-208`):
   a stale pointer after a branch switch silently redirects every script to the wrong
   milestone directory with no error. No state-of-project doc exists for an agent
   starting a fresh session.
5. **Dead weight dilutes compliance.** ~700-900 lines across the 10 skills are
   extension-hook boilerplate for a `.specify/extensions.yml` that doesn't exist
   (guaranteed dead code, 35-50% of each skill's tokens). `speckit-taskstoissues`
   requires a GitHub remote; the repo has none. Stock examples (OAuth2, checkout
   flows) mislead toward web-app framing.
6. **Naming drift, undocumented.** Spec dirs are `NNN-name`, branches are `mN-name`,
   spec IDs are `SPEC-M#-AREA`; no document states the conventions, and script JSON
   output labels the spec-dir basename as `BRANCH`, which is false
   (`common.sh:214-217`).

## 3. Recommended changes (prioritized)

**Status 2026-07-27 — core fixes applied by owner decision.** Items 1-3 are staged
in `scaffolding-patches/` (the review session could not write `.claude/skills/`
directly — install per that folder's README); items 2 (template), 4, 5 are applied
in place (`.specify/templates/overrides/tasks-template.md`, `docs/state.md`,
CLAUDE.md). Item 6 is included in the staged speckit-tasks patch. Item 7 (cleanup)
was deferred.

1. **Customize `speckit-implement`** — the single highest-value change; it closes both
   recurring failure classes at the moment they occur:
   - Pre-gate: read spec.md's `Status:`; unless it is `Approved` with a citation into
     `docs/decisions/`, STOP and request owner approval.
   - Replace the ignore-file step with a mandatory verification step: `Scripts/ci.sh`,
     `swift run dfsim replay Fixtures/replays/smoke.rec --assert-hashes`,
     `determinism-check`, `bench`, and observing behavior via `dfsim ascii`.
   - Completion report MUST include verbatim output of any failure and an explicit
     list of skipped steps. "Should work" is not a result.
2. **Create `.specify/templates/overrides/tasks-template.md`**: mandatory test tasks
   named for spec IDs, a final phase that is the ci.sh/replay/bench gates, Swift
   module paths, web/mobile scaffolding deleted.
3. **Fix `speckit-specify`**: concrete instruction to copy the override template
   (never stock); rewrite the quality checklist so "technology-agnostic" explicitly
   does not apply to the override's required verification commands; completion report
   states "Status is Draft — owner approval in docs/decisions/ required before
   implementation."
4. **Add `docs/state.md`** (~15 lines): active milestone dir + real git branch, spec
   status + decision link, last completed phase/task, pending approvals, next step —
   plus a module/fixture ownership table (gives the "owning agent" rule an addressee).
   Every skill run ends by updating it; CLAUDE.md lists it in "Read these first".
5. **Update CLAUDE.md**: add `docs/decisions/` and `docs/state.md` to "Read these
   first"; document the `NNN-name` dir / `mN-name` branch / `SPEC-M#-AREA` ID
   conventions.
6. **Align `speckit-tasks` with Principle V**: tests are mandatory, not optional.
7. **Cleanup (larger, lower urgency)**: strip dead extension-hook boilerplate from all
   10 skills; delete `speckit-taskstoissues` (no remote); either delete
   `workflow.yml` or wire its gates to write `docs/decisions/` entries — two weaker
   notions of "approved" are worse than one; fix the `BRANCH` label in script output.

## 4. What is already good and should not change

The two template overrides (spec, plan) are excellent — the Determinism Contract,
Performance Budget, and Tick Placement sections are exactly the right design-review
forcing functions. CLAUDE.md's single-source-of-truth pointer to the constitution is
the right call. The research discipline (confidence tags, just-in-time sweeps,
`00-INDEX.md` coverage-gap table) is better than most human teams manage. The
`.specify` bash scripts are robust to the repo's actual naming. Keep all of it.

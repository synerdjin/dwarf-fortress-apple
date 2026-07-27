# Scaffolding patches — pending install

**Created**: 2026-07-27, by the external review session (see
`docs/review-scaffolding-2026-07-27.md` for rationale). The review session could
not write into `.claude/skills/` directly (protected path), so the customized
skills are staged here.

## To install (any agent, or the owner)

```bash
cp scaffolding-patches/speckit-implement.SKILL.md .claude/skills/speckit-implement/SKILL.md
cp scaffolding-patches/speckit-specify.SKILL.md   .claude/skills/speckit-specify/SKILL.md
cp scaffolding-patches/speckit-tasks.SKILL.md     .claude/skills/speckit-tasks/SKILL.md
rm -rf scaffolding-patches
```

Then commit with a message noting the skills are now project-customized
(marker: `metadata.customized` in each file's frontmatter).

## What changed vs stock

- **speckit-implement**: approval gate (spec `Status: Approved` + `docs/decisions/`
  record required before any code); web-tooling ignore-file step replaced with the
  project's real verification gates (ci.sh, replay `--assert-hashes`,
  determinism-check, bench, `dfsim ascii` observation); completion report must
  include verbatim failure output and skipped-step disclosure; `docs/state.md`
  updates; stale `feature.json` cross-check.
- **speckit-specify**: MUST copy `.specify/templates/overrides/spec-template.md`
  (never the stock template — stock lacks SPEC-ID/Status/determinism sections);
  quality checklist rewritten so "no implementation details" no longer instructs
  agents to delete required verification commands; success-criteria examples are
  project examples; completion report carries the "Draft — approval required
  before implement" reminder; naming conventions documented.
- **speckit-tasks**: "Tests are OPTIONAL" reversed to mandatory per constitution
  Principle V; requirement-coverage map (every FR/DR → test task); mandatory final
  Verification phase; Swift-project examples; uses the new
  `.specify/templates/overrides/tasks-template.md`.

The remaining 7 skills are untouched stock. Recommended follow-up cleanup
(deferred by owner decision): strip dead extension-hook boilerplate, delete
`speckit-taskstoissues` (requires a GitHub remote that doesn't exist), reconcile
`workflow.yml`'s unrecorded approval gates with `docs/decisions/`.

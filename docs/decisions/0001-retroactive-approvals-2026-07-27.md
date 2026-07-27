# Decision 0001 — Retroactive approvals

**Date**: 2026-07-27
**Approver**: Djin (project owner), via review session with an independent review agent
**Context**: External review (`docs/review-2026-07-27.md`) found two decisions that the
constitution requires human approval for, taken without recorded approval.

## Approved

1. **SPEC-M1-VIEW (M1 — Seeing the Fortress) is approved**, retroactively covering the
   already-implemented phases 1–3. Spec status line updated to match.

2. **The M3/M6 milestone reorder is approved** (M3 = thermal simulation and
   contaminants; M6 = fluids plus pathfinding), **with a binding condition**:
   M3's performance budget must derive from a measured prototype benchmark on target
   hardware (naive whole-map diffusion vs active-set, at the 200-dwarves /
   144×144×16 scale) — not from the wiki claim in
   `docs/reference/performance-model.md`. If the benchmark contradicts the
   temperature-dominates finding, the ordering question returns to the owner before
   the M3 spec freezes.

## Not approved (pending)

- **Constitution amendments (proposed v1.1.0)** in `docs/review-2026-07-27.md` §6 are
  **proposals only**. The constitution remains at v1.0.0. An implementing agent must
  bring the amendments back to the owner for explicit approval before editing
  `.specify/memory/constitution.md`.

## Process note

Per the constitution's Governance section, human approvals are only real if recorded.
This directory (`docs/decisions/`) is the record. One file per decision, numbered,
with date, approver, and scope. An unrecorded approval did not happen.

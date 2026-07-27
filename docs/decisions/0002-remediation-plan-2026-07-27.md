# Decision 0002 — Review remediation plan and Invariant VI

**Date**: 2026-07-27
**Approver**: Djin (project owner)
**Context**: External review (`docs/review-2026-07-27.md`) delivered a prioritized
remediation backlog (§7) and proposed constitution amendments v1.1.0 (§6).

## Approved

1. **Work the P0 batch first**, then return with the constitution amendments backed by
   evidence from having done the work. Sequence: install the staged scaffolding patches,
   then backlog items 1–7, each landing with the constitution's own guard rule applied —
   break the new check once, confirm it fires, say so in the commit message.

2. **Invariant VI (serialized-state versioning) is adopted in principle**, ahead of the
   rest of the v1.1.0 amendment set. Rationale accepted from the review: there is no
   save/load story at all, and the replay format currently uses struct memory layout *as*
   its schema, so any field reordering silently invalidates every fixture in the
   repository. This is cheapest to fix before M4 adds worldgen and anatomy state.

   The exact wording lands with the full v1.1.0 amendment, which returns for approval
   after the P0 batch. Adoption in principle means: no new serialized format may be added
   before the invariant is written, and the replay container is expected to gain an
   explicit schema.

## Why P0 before amendments

The review's sharpest finding is that two of three previously confessed process failures
**recurred** — fixes were applied to instances rather than to patterns. Amending the
constitution before demonstrating the pattern can actually be closed would repeat that
error at the level of governance: a rule written but not exercised is the same category
of unproven guard the constitution already warns about.

## Binding condition carried forward

Decision 0001's condition on the M3/M6 reorder stands: M3's performance budget must come
from a measured prototype benchmark on target hardware, not from the wiki claim.

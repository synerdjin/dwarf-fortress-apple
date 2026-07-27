---
name: "speckit-specify"
description: "Create or update the feature specification from a natural language feature description."
argument-hint: "Describe the feature you want to specify"
compatibility: "Requires spec-kit project structure with .specify/ directory"
metadata:
  author: "github-spec-kit"
  customized: "dwarf-fortress-apple, 2026-07-27 — override template mandatory, project-aware quality checklist, approval note"
user-invocable: true
disable-model-invocation: false
---


## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Pre-Execution Checks

**Check for extension hooks (before specification)**:
- Check if `.specify/extensions.yml` exists in the project root.
- If it exists, read it and look for entries under the `hooks.before_specify` key
- If the YAML cannot be parsed or is invalid, skip hook checking silently and continue normally
- Filter out hooks where `enabled` is explicitly `false`. Treat hooks without an `enabled` field as enabled by default.
- For each remaining hook, do **not** attempt to interpret or evaluate hook `condition` expressions:
  - If the hook has no `condition` field, or it is null/empty, treat the hook as executable
  - If the hook defines a non-empty `condition`, skip the hook and leave condition evaluation to the HookExecutor implementation
- When constructing slash commands from hook command names, replace dots (`.`) with hyphens (`-`). For example, `speckit.git.commit` → `/speckit-git-commit`.
- For each executable hook, output the following based on its `optional` flag:
  - **Optional hook** (`optional: true`):
    ```
    ## Extension Hooks

    **Optional Pre-Hook**: {extension}
    Command: `/{command}`
    Description: {description}

    Prompt: {prompt}
    To execute: `/{command}`
    ```
  - **Mandatory hook** (`optional: false`):
    ```
    ## Extension Hooks

    **Automatic Pre-Hook**: {extension}
    Executing: `/{command}`
    EXECUTE_COMMAND: {command}

    Wait for the result of the hook command before proceeding to the Outline.
    ```
    After emitting the block above you MUST actually invoke the hook and wait for it to finish before continuing. Run it the same way you would run the command yourself in this agent/session (the invocation may differ from the literal `{command}` id shown above, e.g. a skills-mode agent runs it as `/skill:speckit-...` or `$speckit-...`). Emitting the block alone does not run the hook.
- If no hooks are registered or `.specify/extensions.yml` does not exist, skip silently

## Outline

The text the user typed after `/speckit-specify` in the triggering message **is** the feature description. Assume you always have it available in this conversation even if `$ARGUMENTS` appears literally below. Do not ask the user to repeat it unless they provided an empty command.

Given that feature description, do this:

1. **Generate a concise short name** (2-4 words) for the milestone:
   - Extract the most meaningful keywords; action-noun format when possible
   - Keep it concise but descriptive (e.g., "thermal-simulation", "fluids-pathfinding")

   **Project naming conventions** (all three coexist; keep them consistent):
   - Spec directory: `specs/NNN-<short-name>` (sequential NNN)
   - Git branch: `mN-<short-name>` (milestone number)
   - Spec ID: `SPEC-M<N>-<AREA>` (cited by tests; frozen once code references it)

2. **Branch creation** (optional, via hook):

   If a `before_specify` hook ran successfully in the Pre-Execution Checks above, it will have created/switched to a git branch and output JSON containing `BRANCH_NAME` and `FEATURE_NUM`. Note these values for reference, but the branch name does **not** dictate the spec directory name.

   If no hook exists (this repo currently has none), create the `mN-<short-name>`
   branch yourself before writing files.

3. **Create the spec feature directory**:

   Specs live under the default `specs/` directory unless the user explicitly provides `SPECIFY_FEATURE_DIRECTORY`.

   **Resolution order for `SPECIFY_FEATURE_DIRECTORY`**:
   1. If the user explicitly provided `SPECIFY_FEATURE_DIRECTORY`, use it as-is
   2. Otherwise, auto-generate it under `specs/`: next available 3-digit `NNN` prefix, then `NNN-<short-name>`

   **Create the directory and spec file**:
   - `mkdir -p SPECIFY_FEATURE_DIRECTORY`
   - **Copy `.specify/templates/overrides/spec-template.md` to `SPECIFY_FEATURE_DIRECTORY/spec.md`. NEVER use `.specify/templates/spec-template.md` (the stock template) — the override carries the sections this project cannot ship without: SPEC-ID header, Status field, consumer contracts, Determinism Requirements, command-named verification, Research Basis.** If the override file is missing, STOP and report it; do not fall back silently.
   - Set `SPEC_FILE` to `SPECIFY_FEATURE_DIRECTORY/spec.md`
   - Persist the resolved path to `.specify/feature.json`:
     ```json
     {
       "feature_directory": "<resolved feature dir>"
     }
     ```
     Write the actual resolved directory path value (for example, `specs/002-thermal-simulation`), not the literal string `SPECIFY_FEATURE_DIRECTORY`.
   - Also record the new milestone (dir, branch, Status: Draft) in `docs/state.md`.

   **IMPORTANT**:
   - You must only create one feature per `/speckit-specify` invocation
   - The spec directory and file are always created by this command, never by the hook

4. Load `.specify/templates/overrides/spec-template.md` to understand required sections.

5. **REQUIRED**: Load `.specify/memory/constitution.md` for project principles and governance constraints, and `docs/reference/00-INDEX.md` to find the research this spec must build on. **Research precedes specs** (constitution): if the mechanics this milestone depends on are listed as a coverage gap, the research sweep comes first — say so and stop.

6. Follow this execution flow:
    1. Parse user description from arguments
       If empty: ERROR "No feature description provided"
    2. Extract key concepts from description
       Identify: actors, actions, data, constraints
    3. For unclear aspects:
       - Make informed guesses based on context and the project's reference docs
       - Only mark with [NEEDS CLARIFICATION: specific question] if:
         - The choice significantly impacts feature scope or observable behavior
         - Multiple reasonable interpretations exist with different implications
         - No reasonable default exists
       - **LIMIT: Maximum 3 [NEEDS CLARIFICATION] markers total**
       - Every `[UNKNOWN]`-tagged DF behavior the milestone depends on needs an explicit decision recorded in Research Basis — those do not count against the marker limit but may not be left silent
    4. Fill Consumer Scenarios & Testing section
       The consumer is sometimes a player and sometimes another subsystem — write whichever is honest; do not invent player narratives for subsystem work
    5. Generate Functional Requirements
       Each requirement must be testable by a named command
    6. Define Determinism Requirements (DR-001 hash stability across runs and across the full `determinism-check` thread set is mandatory; add milestone-specific DRs)
    7. Define Success Criteria and Performance Criteria
       Measurable, with the exact `dfsim` command that verifies each; perf criteria state ms/tick at a stated scale
    8. Identify Key Entities (if the milestone introduces sim state)
    9. Return: SUCCESS (spec ready for planning)

7. Write the specification to SPEC_FILE using the override template structure, replacing placeholders with concrete details while preserving section order and headings. Set the header: `**ID**: SPEC-M<N>-<AREA> | **Date**: <today> | **Status**: Draft`.

8. **Specification Quality Validation**: After writing the initial spec, validate it against quality criteria:

   a. **Create Spec Quality Checklist**: Generate a checklist file at `SPECIFY_FEATURE_DIRECTORY/checklists/requirements.md` with these validation items:

      ```markdown
      # Specification Quality Checklist: [MILESTONE NAME]

      **Purpose**: Validate specification completeness and quality before proceeding to planning
      **Created**: [DATE]
      **Feature**: [Link to spec.md]

      ## Content Quality

      - [ ] No design details (data structures, algorithms, tick placement — those belong in plan.md)
      - [ ] EXCEPTION (project rule): verification commands (`dfsim ...`), spec IDs, determinism requirements, and ms/tick budgets are REQUIRED content, not implementation leakage
      - [ ] Consumer scenarios are honest (player-facing vs subsystem-facing, per the template note)
      - [ ] All mandatory sections completed

      ## Requirement Completeness

      - [ ] No [NEEDS CLARIFICATION] markers remain
      - [ ] Requirements are testable by a named command, and unambiguous
      - [ ] Determinism Requirements present (DR-001 at minimum)
      - [ ] Performance criteria state ms/tick at a stated scale, measured by `dfsim bench`
      - [ ] Edge cases from the template answered or ruled out
      - [ ] Research Basis cites docs/reference/ with confidence tags; every [UNKNOWN] has an explicit decision
      - [ ] Divergences from DF declared as [DIVERGENCE: <rule> because <reason>]
      - [ ] Scope is clearly bounded (Out of Scope filled in)
      - [ ] Assumptions identified

      ## Feature Readiness

      - [ ] Every FR/DR has clear acceptance criteria
      - [ ] Header has SPEC-ID and Status: Draft
      - [ ] No test in the codebase will cite an ID this spec does not declare

      ## Notes

      - Items marked incomplete require spec updates before `/speckit-clarify` or `/speckit-plan`
      ```

   b. **Run Validation Check**: Review the spec against each checklist item; document specific issues found (quote relevant spec sections)

   c. **Handle Validation Results**:

      - **If all items pass**: Mark checklist complete and proceed to the Mandatory Post-Execution Hooks section

      - **If items fail (excluding [NEEDS CLARIFICATION])**:
        1. List the failing items and specific issues
        2. Update the spec to address each issue
        3. Re-run validation until all items pass (max 3 iterations)
        4. If still failing after 3 iterations, document remaining issues in checklist notes and warn user

      - **If [NEEDS CLARIFICATION] markers remain**:
        1. Extract all [NEEDS CLARIFICATION: ...] markers from the spec
        2. **LIMIT CHECK**: If more than 3 markers exist, keep only the 3 most critical (by scope/determinism/performance impact) and make informed guesses for the rest
        3. For each clarification needed (max 3), present options to the user as a table of lettered options with implications
        4. Number questions sequentially (Q1, Q2, Q3 - max 3 total); present all questions together before waiting for responses
        5. Update the spec by replacing each marker with the user's selected or provided answer
        6. Re-run validation after all clarifications are resolved

   d. **Update Checklist**: After each validation iteration, update the checklist file with current pass/fail status

## Mandatory Post-Execution Hooks

**You MUST complete this section before reporting completion to the user.**

Check if `.specify/extensions.yml` exists in the project root.
- If it does not exist, or no hooks are registered under `hooks.after_specify`, skip to the Completion Report.
- If it exists, read it and look for entries under the `hooks.after_specify` key.
- If the YAML cannot be parsed or is invalid, skip hook checking silently and continue to the Completion Report.
- Filter out hooks where `enabled` is explicitly `false`. Treat hooks without an `enabled` field as enabled by default.
- For each remaining hook, do **not** attempt to interpret or evaluate hook `condition` expressions:
  - If the hook has no `condition` field, or it is null/empty, treat the hook as executable
  - If the hook defines a non-empty `condition`, skip the hook and leave condition evaluation to the HookExecutor implementation
- When constructing slash commands from hook command names, replace dots (`.`) with hyphens (`-`). For example, `speckit.git.commit` → `/speckit-git-commit`.
- For each executable hook, output the following based on its `optional` flag:
  - **Mandatory hook** (`optional: false`) — **You MUST emit `EXECUTE_COMMAND:` for each mandatory hook**:
    ```
    ## Extension Hooks

    **Automatic Hook**: {extension}
    Executing: `/{command}`
    EXECUTE_COMMAND: {command}
    ```
    After emitting the block above you MUST actually invoke the hook and wait for it to finish before continuing. Run it the same way you would run the command yourself in this agent/session (the invocation may differ from the literal `{command}` id shown above, e.g. a skills-mode agent runs it as `/skill:speckit-...` or `$speckit-...`). Emitting the block alone does not run the hook.
  - **Optional hook** (`optional: true`):
    ```
    ## Extension Hooks

    **Optional Hook**: {extension}
    Command: `/{command}`
    Description: {description}

    Prompt: {prompt}
    To execute: `/{command}`
    ```

## Completion Report

Report completion to the user with:
- `SPECIFY_FEATURE_DIRECTORY` — the feature directory path
- `SPEC_FILE` — the spec file path
- Checklist results summary
- Readiness for the next phase (`/speckit-clarify` or `/speckit-plan`)
- **This exact reminder: "Spec Status is Draft. Owner approval recorded in `docs/decisions/` is required before `/speckit-implement` may run (constitution, Governance). Design (`/speckit-plan`) may proceed on a Draft; implementation may not."**

## Quick Guidelines

- State **WHAT must be true**, not how it is built (no data structures, algorithms, or tick placement — those live in plan.md).
- **Project override of the stock rule "written for non-technical stakeholders":** the consumers of most specs here are other subsystems and verifying agents. Concrete `dfsim` verification commands, spec IDs, determinism requirements, and ms/tick numbers are mandatory spec content. "Technology-agnostic" means no Swift/Metal/storage-layout detail — it does not mean vague.
- DO NOT create any checklists that are embedded in the spec. That will be a separate command.

### Section Requirements

- **Mandatory sections**: Must be completed for every milestone (see override template)
- When a section doesn't apply, remove it entirely (don't leave as "N/A")

### For AI Generation

1. **Make informed guesses** from `docs/reference/` and DF conventions; **document assumptions**
2. **Limit clarifications**: max 3 markers, prioritized scope > determinism > performance > detail
3. **Think like the verifying agent**: every requirement must name the command that would fail if it were false

**Success criteria examples for THIS project**:

- Good: "A designated 3-tile stairwell is fully excavated by tick 4000, visible via `swift run dfsim ascii --tick 4000 --z 6`"
- Good: "Replay of the milestone fixture produces identical hashes at all checkpoints across every thread count `determinism-check` defaults to"
- Good: "200-dwarf scenario stays within 2.0 ms/tick, measured by `dfsim bench --scenario 200-dwarves`"
- Bad: "Dwarves dig efficiently" (no command can fail it)
- Bad: "Uses a flow-field pathfinder over 16×16 sectors" (design, belongs in plan.md)

## Done When

- [ ] Specification written to `SPEC_FILE` from the **override** template, header carries SPEC-ID and `Status: Draft`
- [ ] Validated against the quality checklist (with the project exceptions applied)
- [ ] `docs/state.md` updated with the new milestone
- [ ] Extension hooks dispatched or skipped according to the rules above
- [ ] Completion reported with the approval reminder included verbatim

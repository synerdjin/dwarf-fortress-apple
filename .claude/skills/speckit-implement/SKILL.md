---
name: "speckit-implement"
description: "Execute the implementation plan by processing and executing all tasks defined in tasks.md"
argument-hint: "Optional implementation guidance or task filter"
compatibility: "Requires spec-kit project structure with .specify/ directory"
metadata:
  author: "github-spec-kit"
  customized: "dwarf-fortress-apple, 2026-07-27 — approval gate, project verification gates, honest reporting"
user-invocable: true
disable-model-invocation: false
---


## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Pre-Execution Checks

**Check for extension hooks (before implementation)**:
- Check if `.specify/extensions.yml` exists in the project root.
- If it exists, read it and look for entries under the `hooks.before_implement` key
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

1. Run `.specify/scripts/bash/check-prerequisites.sh --json --require-tasks --include-tasks` from repo root and parse FEATURE_DIR and AVAILABLE_DOCS list. All paths must be absolute. For single quotes in args like "I'm Groot", use escape syntax: e.g 'I'\''m Groot' (or double-quote if possible: "I'm Groot").

   Then confirm FEATURE_DIR matches what you believe you are working on (check
   `docs/state.md` and the current git branch). `.specify/feature.json` is a
   global pointer that can be stale after a branch switch — if it disagrees with
   `docs/state.md` or the branch, STOP and reconcile before touching code.

2. **Approval gate (PROJECT RULE — constitution Governance, non-negotiable)**:
   - Read the header of FEATURE_DIR/spec.md and find the `Status:` field.
   - Implementation may begin **only** if Status is `Approved` AND the approval is
     recorded in `docs/decisions/` (the status line and the decision file should
     reference each other).
   - **An unrecorded approval did not happen.** A checklist, a plan, an earlier
     agent's claim, or your own confidence is not a substitute.
   - If the status is anything else (Draft, Clarified, awaiting approval, absent):
     **STOP.** Report which spec, its current status, and that implementation is
     blocked until the owner's approval is recorded in `docs/decisions/`.

3. **Check checklists status** (if FEATURE_DIR/checklists/ exists):
   - Scan all checklist files in the checklists/ directory
   - For each checklist, count:
     - Total items: All lines matching `- [ ]` or `- [X]` or `- [x]`
     - Completed items: Lines matching `- [X]` or `- [x]`
     - Incomplete items: Lines matching `- [ ]`
   - Create a status table:

     ```text
     | Checklist | Total | Completed | Incomplete | Status |
     |-----------|-------|-----------|------------|--------|
     | ux.md     | 12    | 12        | 0          | ✓ PASS |
     | test.md   | 8     | 5         | 3          | ✗ FAIL |
     ```

   - Calculate overall status:
     - **PASS**: All checklists have 0 incomplete items
     - **FAIL**: One or more checklists have incomplete items

   - **If any checklist is incomplete**:
     - Display the table with incomplete item counts
     - **STOP** and ask: "Some checklists are incomplete. Do you want to proceed with implementation anyway? (yes/no)"
     - Wait for user response before continuing
     - If user says "no" or "wait" or "stop", halt execution
     - If user says "yes" or "proceed" or "continue", proceed to step 4

   - **If all checklists are complete**:
     - Display the table showing all checklists passed
     - Automatically proceed to step 4

   Note the limit of this gate: these checklists were generated and graded by an
   agent. They are advisory. The falsifiable gates are step 2 (approval) and
   step 8 (verification); a green checklist excuses neither.

4. Load and analyze the implementation context:
   - **REQUIRED**: Read tasks.md for the complete task list and execution plan
   - **REQUIRED**: Read plan.md for tech stack, architecture, and file structure
   - **REQUIRED**: Read `.specify/memory/constitution.md` — the five invariants
     and the Determinism Rules for Parallel Code govern every line you write
   - **REQUIRED**: Read `CLAUDE.md` (verification commands, conventions) and
     `docs/known-issues.md` (do not re-fight settled investigations)
   - **IF EXISTS**: Read data-model.md for entities and relationships
   - **IF EXISTS**: Read contracts/ for API specifications and test requirements
   - **IF EXISTS**: Read research.md for technical decisions and constraints
   - **IF EXISTS**: Read quickstart.md for integration scenarios

5. **Project setup**: this is a hermetic Swift package (no third-party
   dependencies, no Docker, no JS tooling). `.gitignore` already exists. Do NOT
   generate ignore files, lint configs, or other tooling scaffolding; a task
   that seems to need them is a signal to re-read the plan.

6. Parse tasks.md structure and extract:
   - **Task phases**, **task dependencies**, **task details** (ID, description,
     file paths, parallel markers [P]), **execution flow**

7. Execute implementation following the task plan:
   - **Phase-by-phase execution**: Complete each phase before moving to the next
   - **Respect dependencies**: Run sequential tasks in order, parallel tasks [P] can run together
   - **Tests before code**: test tasks run before their corresponding implementation tasks; tests are named for the spec requirement they verify (`testSPEC_M3_PATHS_...`) and the cited ID must exist
   - **File-based coordination**: Tasks affecting the same files must run sequentially
   - **Validation checkpoints**: Verify each phase completion before proceeding
   - **New guards must be proven**: when you add a check whose value is catching
     a rare condition, break it deliberately once, confirm it fires, and say so
     in the commit message
   - **Golden hashes are contracts**: if your change alters another module's
     replay fixture hashes, that is a conversation recorded in `docs/state.md` /
     with the owning agent — never a silent re-bless

8. **Verification (PROJECT RULE — never report done without this)**:

   Run, from repo root, and capture output:

   ```bash
   Scripts/ci.sh
   swift run dfsim replay Fixtures/replays/smoke.rec --assert-hashes
   swift run dfsim determinism-check
   swift run dfsim bench --scenario 200-dwarves --ticks 10000
   ```

   And **look at the behavior**, not just the exit codes:

   ```bash
   swift run dfsim ascii --tick 500 --z 12   # adjust scenario/tick/z to the feature
   ```

   A change that "should work" and a change you have watched produce the right
   tiles are different things. If the milestone added a `dfsim` verb (constitution
   Principle V), exercise it here.

9. Progress tracking and error handling:
   - Report progress after each completed task
   - Halt execution if any non-parallel task fails
   - For parallel tasks [P], continue with successful tasks, report failed ones
   - Provide clear error messages with context for debugging
   - Suggest next steps if implementation cannot proceed
   - **IMPORTANT** For completed tasks, make sure to mark the task off as [X] in the tasks file.
   - Update `docs/state.md` (last completed phase/task, anything pending) at
     minimum at each phase boundary and at session end — the next agent resumes
     from it.

## Mandatory Post-Execution Hooks

**You MUST complete this section before reporting completion to the user.**

Check if `.specify/extensions.yml` exists in the project root.
- If it does not exist, or no hooks are registered under `hooks.after_implement`, skip to the Completion Report.
- If it exists, read it and look for entries under the `hooks.after_implement` key.
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

Report final status. **Honesty rules (constitution / CLAUDE.md working agreement):**

- Include the verification results from step 8 — verbatim output for anything
  that failed, and the final summary line for what passed.
- If any step was skipped, say which and why. "Should work" is not a result.
- If tests fail, the report says so with the output; do not summarize failure
  as success, and do not re-bless golden hashes to make a gate pass.
- State which spec requirements (FR/DR/SC/PC IDs) are now verified by which
  tests/commands.

## Done When

- [ ] Approval gate passed: spec Status is `Approved` with a `docs/decisions/` record
- [ ] All tasks in tasks.md completed and marked `[X]`
- [ ] All step-8 verification commands run, with output reported honestly
- [ ] Behavior observed via `dfsim ascii` (or the milestone's verb), not inferred
- [ ] `docs/state.md` updated
- [ ] Extension hooks dispatched or skipped according to the rules above
- [ ] Completion reported with per-requirement verification status

---
name: "speckit-tasks"
description: "Generate an actionable, dependency-ordered tasks.md for the feature based on available design artifacts."
argument-hint: "Optional task generation constraints"
compatibility: "Requires spec-kit project structure with .specify/ directory"
metadata:
  author: "github-spec-kit"
  customized: "dwarf-fortress-apple, 2026-07-27 — tests mandatory per constitution V, verification phase, override template"
user-invocable: true
disable-model-invocation: false
---


## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Pre-Execution Checks

**Check for extension hooks (before tasks generation)**:
- Check if `.specify/extensions.yml` exists in the project root.
- If it exists, read it and look for entries under the `hooks.before_tasks` key
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

1. **Setup**: Run `.specify/scripts/bash/setup-tasks.sh --json` from repo root and parse FEATURE_DIR, TASKS_TEMPLATE, and AVAILABLE_DOCS list. `FEATURE_DIR` and `TASKS_TEMPLATE` must be absolute paths when provided. **Verify TASKS_TEMPLATE resolved to `.specify/templates/overrides/tasks-template.md` — if it resolved to the stock template, use the override path explicitly instead.** For single quotes in args like "I'm Groot", use escape syntax: e.g 'I'\''m Groot' (or double-quote if possible: "I'm Groot").

2. **Load design documents**: Read from FEATURE_DIR:
   - **Required**: plan.md (modules, structure, Determinism Contract, Performance Budget, Tick Placement tables), spec.md (scenarios with priorities, FR/DR/SC/PC requirements)
   - **Required**: `.specify/memory/constitution.md` — Principle V makes test tasks and a headless `dfsim` verb mandatory for every module this milestone touches
   - **Optional**: data-model.md (entities), contracts/ (interface contracts), research.md (decisions), quickstart.md (test scenarios)

3. **Execute task generation workflow**:
   - Load plan.md and extract modules touched, project structure, systems and their tick phases
   - Load spec.md and extract scenarios with their priorities (P1, P2, P3, etc.) and every FR/DR/SC/PC ID
   - If data-model.md exists: Extract entities and map to scenarios
   - If contracts/ exists: Map interface contracts to scenarios
   - If research.md exists: Extract decisions for setup tasks
   - Generate tasks organized by scenario (see Task Generation Rules below)
   - Generate dependency graph showing scenario completion order
   - Create parallel execution examples per scenario
   - Validate task completeness: every FR and DR in the spec is covered by at least one test task; every new system has a Tick Placement row in plan.md; the milestone's `dfsim` verb has a task

4. **Generate tasks.md**: Use the override template as structure. Fill with:
   - Correct milestone name from plan.md
   - Phase 1: Setup tasks
   - Phase 2: Foundational tasks (blocking prerequisites for all scenarios)
   - Phase 3+: One phase per scenario (in priority order from spec.md), each including: goal, independent test criteria, **test tasks (mandatory)**, implementation tasks
   - Final Phase: **Verification** — run `Scripts/ci.sh`, replay fixtures with `--assert-hashes`, `determinism-check`, `bench` against the plan's budget, and observe behavior via `dfsim ascii`; record/refresh replay fixtures per the plan's Replay Fixtures section; prove any newly added guard by breaking it once
   - All tasks must follow the strict checklist format (see Task Generation Rules below)
   - Clear file paths for each task
   - Dependencies section showing scenario completion order
   - Parallel execution examples per scenario

## Mandatory Post-Execution Hooks

**You MUST complete this section before reporting completion to the user.**

Check if `.specify/extensions.yml` exists in the project root.
- If it does not exist, or no hooks are registered under `hooks.after_tasks`, skip to the Completion Report.
- If it exists, read it and look for entries under the `hooks.after_tasks` key.
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

Output path to generated tasks.md and summary:
- Total task count
- Task count per scenario
- Requirement coverage: every FR/DR ID mapped to the test task that verifies it (list any uncovered ID as a FAIL)
- Parallel opportunities identified
- Independent test criteria for each scenario
- Format validation: Confirm ALL tasks follow the checklist format (checkbox, ID, labels, file paths)

Context for task generation: $ARGUMENTS

The tasks.md should be immediately executable - each task must be specific enough that an LLM can complete it without additional context.

## Task Generation Rules

**CRITICAL**: Tasks MUST be organized by scenario to enable independent implementation and testing.

**Tests are MANDATORY** (constitution Principle V — this project overrides the stock spec-kit rule): every module touched ships unit tests in the same milestone; test tasks precede their implementation tasks; tests are named for the spec requirement they verify (`testSPEC_M<N>_<AREA>_...`) and the cited spec ID must exist. A milestone that introduces observable behavior also gets a headless `dfsim` verb task.

### Checklist Format (REQUIRED)

Every task MUST strictly follow this format:

```text
- [ ] [TaskID] [P?] [Story?] Description with file path
```

**Format Components**:

1. **Checkbox**: ALWAYS start with `- [ ]` (markdown checkbox)
2. **Task ID**: Sequential number (T001, T002, T003...) in execution order
3. **[P] marker**: Include ONLY if task is parallelizable (different files, no dependencies on incomplete tasks)
4. **[Story] label**: REQUIRED for scenario phase tasks only
   - Format: [US1], [US2], [US3], etc. (maps to scenarios from spec.md)
   - Setup phase: NO story label
   - Foundational phase: NO story label
   - Scenario phases: MUST have story label
   - Verification phase: NO story label
5. **Description**: Clear action with exact file path

**Examples (this project's layout)**:

- ✅ CORRECT: `- [ ] T001 Add TemperatureField block store in Sources/DFSim/TemperatureField.swift`
- ✅ CORRECT: `- [ ] T004 [P] [US1] Test SPEC-M3-HEAT diffusion conservation in Sources/DFTests/ThermalTests.swift`
- ✅ CORRECT: `- [ ] T014 [US1] Register thermal system with declared reads/writes in Sources/DFSim/Fortress.swift`
- ❌ WRONG: `- [ ] Create heat model` (missing ID, story label, file path)
- ❌ WRONG: `T001 [US1] Create model` (missing checkbox)

### Task Organization

1. **From Scenarios (spec.md)** - PRIMARY ORGANIZATION:
   - Each scenario (P1, P2, P3...) gets its own phase
   - Map all related components to their scenario: systems, components, commands, tests, `dfsim` verb behavior
   - Mark scenario dependencies (most should be independent)

2. **From Contracts**:
   - Map each interface contract → the scenario it serves; contract test task [P] before implementation in that scenario's phase

3. **From Data Model**:
   - Map each entity/component to the scenario(s) that need it; if it serves multiple, put it in the earliest or the Foundational phase
   - New component types get a padding/BitwiseCopyable assertion task (constitution IV)

4. **From the plan's Determinism Contract**:
   - Any parallel decomposition gets a determinism test task (hash equality across partition counts)
   - Any new RNG domain/sub-stream gets a replay-stability test task

### Phase Structure

- **Phase 1**: Setup
- **Phase 2**: Foundational (blocking prerequisites - MUST complete before scenarios)
- **Phase 3+**: Scenarios in priority order (P1, P2, P3...)
  - Within each: Tests → Components/Systems → Commands → Integration
  - Each phase should be a complete, independently verifiable increment
- **Final Phase**: Verification (ci.sh, replay fixtures, determinism-check, bench vs budget, `dfsim ascii` observation, guard-proving)

## Done When

- [ ] tasks.md generated from the override template with all phases, task IDs, and file paths
- [ ] Every FR/DR mapped to a test task; tests precede implementation
- [ ] Final Verification phase present
- [ ] Extension hooks dispatched or skipped according to the rules above
- [ ] Completion reported with task count, coverage map, and scenario breakdown

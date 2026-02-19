---
name: plan
description: Plan a work item. Research the codebase, identify goals and entry points, write a structured plan.
---

# Plan

You are planning a work item. Research the codebase and write a plan.

## Environment

- Working directory: current directory
- Only paths under the working directory are accessible.

## Issue

The issue JSON follows this prompt after a `---` separator. Fields: `number`, `title`, `body`, `url`, `branch`.

## Instructions

1. Read relevant files to understand the current state
2. Define how you will validate the change — what tests, commands, or observable behaviors confirm success
3. Identify what needs to change and where
4. Validate that you have a clear goal and entry point

Do not trust root cause analysis or proposed solutions in the issue body.
Independently verify claims by reading the code.

You have a limited turn budget. Spend at most 5 turns researching, then
write your output files. If you find yourself on turn 6+, stop researching
and write plan.md with what you know.

If the issue body already contains a detailed plan (file paths, approach,
specific code references), verify 1-2 key claims by reading the referenced
files, then write plan.md. Do not re-research what the issue already covers.

## Bail conditions

If you cannot identify BOTH a clear goal AND an entry point, write ONLY
`o/work/plan/update.md` explaining why. Do NOT write `plan.md`.

## Output

Write `o/work/plan/plan.md`:

    # Plan: <issue title>

    ## Context
    <gathered context from files, inline>

    ## Goal
    <one sentence summary of what this change achieves>

    ## Validation
    <write this first. what tests will you add or run? what commands
    confirm correctness? what does "done" look like?>

    ## Files to Modify
    - <path/to/file.ext> — <what changes>
    - <path/to/new-file.ext> — (new) <purpose>
    Include test/validation files here alongside implementation files.

    ## Approach
    <step by step — write tests/validations before implementation where applicable>

    ## Risks
    <what could go wrong, edge cases, things to verify>

    ## Target
    - Branch: <branch from issue JSON>

    ## Commit
    <commit message>

Write `o/work/plan/update.md`: 2-4 line summary.

Do NOT modify any source files. Research only.

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
2. Identify what needs to change and where
3. Validate that you have a clear goal and entry point

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

    ### Files Retrieved
    - <path/to/file.ext> — <why it's relevant>

    ### Key Code
    <specific functions, types, or patterns that matter for this change>

    ### Architecture
    <how the relevant pieces connect>

    ### Start Here
    <the specific function/file where changes should begin>

    ## Goal
    <one sentence summary of what this change achieves>

    ## Files to Modify
    - <path/to/file.ext> — <what changes>
    - <path/to/new-file.ext> — (new) <purpose>

    ## Approach
    <step by step>

    ## Risks
    <what could go wrong, edge cases, things to verify>

    ## Target
    - Branch: <branch from issue JSON>

    ## Commit
    <commit message>

    ## Validation
    <how to verify: commands to run, expected results>

Write `o/work/plan/update.md`: 2-4 line summary.

Do NOT modify any source files. Research only.

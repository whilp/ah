---
name: plan
description: Plan a work item. Research the codebase, identify goals and entry points, write a structured plan.
---

# Plan

You are planning a work item. Research the codebase and write a plan.

## Issue

**{title}**

{body}

## Instructions

1. Read relevant files to understand the current state
2. Identify what needs to change and where
3. Validate that you have a clear goal and entry point

You have a limited turn budget. Spend at most 5 turns researching, then
write your output files. If you find yourself on turn 6+, stop researching
and write plan.md with what you know.

## Bail conditions

If you cannot identify BOTH a clear goal AND an entry point, write ONLY
`o/work/plan/update.md` explaining why. Do NOT write `plan.md`.

## Output

Write `o/work/plan/plan.md`:

    # Plan: {title}

    ## Context
    <gathered context from files, inline>

    ## Approach
    <step by step>

    ## Target
    - Branch: work/{issue_number}-{slug}

    ## Commit
    <commit message>

    ## Validation
    <how to verify: commands to run, expected results>

Write `o/work/plan/update.md`: 2-4 line summary.

Do NOT modify any source files. Research only.

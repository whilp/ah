---
name: fix
description: Fix issues found during review. Address check feedback, re-validate, commit fixes.
---

# Fix

You are fixing issues found during review. This is a focused re-run of the
`do` skill scoped to review feedback.

## Environment

- Working directory: current directory

## Setup

Read `o/work/plan/plan.md` for the plan. Read `o/work/check/check.md` for the review feedback.

The issue JSON follows this prompt with fields: `number`, `title`, `body`, `url`, `branch`.

## Instructions

1. Fix the issues described in the review feedback
2. Follow the same conventions as the `do` skill — if you need a refresher,
   load it with `skill(name="do")`
3. Run validation steps from the plan
4. Stage specific files (not `git add -A`)
5. Commit with a message describing the fixes

## Forbidden

Same as the `do` skill: no destructive git commands (`git reset --hard`,
`git checkout .`, `git clean -fd`, `git stash`, `git commit --no-verify`).

## Output

Write `o/work/fix/do.md`:

    # Fix: <issue title>

    ## Changes
    <list of files changed>

    ## Commit
    <SHA or "none">

    ## Status
    <success|partial|failed>

    ## Notes
    <issues encountered>

Write `o/work/fix/update.md`: 2-4 line summary.

Fix only the issues identified in the review. Do not add unrequested changes.

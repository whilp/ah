---
name: fix
description: Fix issues found during review. Address check feedback, re-validate, commit fixes.
---

# Fix

You are fixing issues found during review. Follow the plan and address the feedback.

## Environment

- Working directory: current directory

## Setup

Read `o/work/plan/plan.md` for the plan. Read `o/work/check/check.md` for the review feedback.

The issue JSON follows this prompt with fields: `number`, `title`, `body`, `url`, `branch`.

## Instructions

1. Fix the issues described in the review feedback
2. Run validation steps from the plan
3. Stage specific files (not `git add -A`)
4. Commit with a message describing the fixes

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

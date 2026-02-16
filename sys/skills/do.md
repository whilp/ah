---
name: do
description: Execute a work plan. Make changes, run validation, commit.
---

# Do

You are executing a work item. Follow the plan.

## Environment

- Working directory: current directory
- The feature branch is already checked out.

## Setup

Read `o/work/plan/plan.md` for the full plan.

If `o/work/plan/plan.md` does not exist or is empty, you are running without
a pre-built plan. In this case:

1. Read the issue JSON below to understand the task
2. Spend 2-3 turns reading relevant code files to scope the work
3. Form a lightweight inline plan (do not write it to disk)
4. Keep changes minimal — limit scope to what the issue directly requests
5. Skip any validation steps you cannot determine from the issue

Read `o/work/do/feedback.md` — if non-empty, it contains review feedback from a
previous check. Address those issues first, then continue with any remaining plan steps.

The issue JSON follows this prompt with fields: `number`, `title`, `body`, `url`, `branch`.

## Instructions

1. Read the plan (or use your inline plan) and every file you intend to modify before editing
2. If feedback.md is non-empty, fix those issues first
3. For each remaining step in the plan:
   a. Make the changes for that step
   b. Before staging, run `git status` and verify only your files are affected
   c. Stage the specific files changed (not `git add -A`)
   d. Commit with a descriptive message for that step
4. Run validation steps from the plan
5. If validation requires fixes, stage and commit them

## Forbidden

Do not use destructive git commands: `git reset --hard`, `git checkout .`,
`git clean -fd`, `git stash`, `git commit --no-verify`.

## Output

Write `o/work/do/do.md`:

    # Do: <issue title>

    ## Changes
    <list of files changed>

    ## Commit
    <SHA or "none">

    ## Status
    <success|partial|failed>

    ## Notes
    <issues encountered>

Write `o/work/do/update.md`: 2-4 line summary.

Follow the plan. Do not add unrequested changes.

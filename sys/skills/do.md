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

Read `.ah/plan/plan.md` for the full plan.

If `.ah/plan/plan.md` does not exist or is empty, you are running without
a pre-built plan. In this case:

1. Read the issue JSON below to understand the task
2. Spend 2-3 turns reading relevant code files to scope the work
3. Form a lightweight inline plan (do not write it to disk)
4. Keep changes minimal — limit scope to what the issue directly requests
5. Skip any validation steps you cannot determine from the issue

Read `.ah/do/feedback.md` — if non-empty, it contains review feedback from a
previous check. Address those issues first, then continue with any remaining plan steps.

The issue JSON follows this prompt with fields: `number`, `title`, `body`, `url`, `branch`.

## Instructions

Follow red/green TDD to implement the plan.

1. Read the plan (or use your inline plan) and every file you intend to modify before editing
2. If feedback.md is non-empty, fix those issues first
3. Maintain a running list of files you modify. After each edit or write, note the file path. Use this list for staging (`git add`) and for the Changes section in do.md.
4. For each remaining step in the plan:
   a. If the plan includes tests or validation code for this step, write those first
   b. Make the implementation changes
   c. Run validation steps relevant to this step, where applicable
   d. Before staging, run `git status` and verify only your files are affected
   e. Stage the specific files changed (not `git add -A`)
   f. Commit with a descriptive message for that step
5. Run any remaining validation steps from the plan
6. If validation requires fixes, stage and commit them

## Forbidden

Do not use destructive git commands: `git reset --hard`, `git checkout .`,
`git clean -fd`, `git stash`, `git commit --no-verify`.

## Output

Write `.ah/do/do.md`:

    # Do: <issue title>

    ## Changes
    <list of files changed>

    ## Commit
    <SHA or "none">

    ## Status
    <success|partial|failed>

    ## Notes
    <issues encountered>

Write `.ah/do/update.md`: 2-4 line summary.

Follow the plan. Do not add unrequested changes.

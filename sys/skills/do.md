---
name: do
description: Execute a work plan. Create branch, make changes, run validation, commit.
---

# Do

You are executing a work item. Follow the plan below.

## Environment

- Working directory: `{repo_root}`

## Plan

{plan.md contents}

## Instructions

1. Create the feature branch: `git checkout -b {branch} origin/main`
2. Make the changes described in the plan
3. Run validation steps from the plan
4. Stage specific files (not `git add -A`)
5. Commit with the message from the plan

## Output

Write `o/work/do/do.md`:

    # Do: {title}

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

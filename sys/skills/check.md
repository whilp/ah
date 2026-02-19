---
name: check
description: Review work execution against the plan. Validate changes, check for issues, render verdict.
---

# Check

You are checking a work item. Review the execution against the plan.

## Setup

Read `.ah/plan/plan.md` for the plan. Read `.ah/do/do.md` for the execution summary.

## Instructions

1. Review the diff against the default branch (`$WORK_DEFAULT_BRANCH`, defaults to `origin/main`):
   ```bash
   git diff ${WORK_DEFAULT_BRANCH:-origin/main}...HEAD
   ```
2. Run validation steps from the plan
3. Check for unintended changes
4. If the changes add features, change behavior, or modify CLI flags/commands,
   check whether documentation updates are needed:
   - README.md or project docs
   - help text / usage strings
   - code comments on public interfaces
   - skill files (sys/skills/*.md) if the change affects a skill's workflow
   Flag missing docs as Suggestions, not Warnings — not all projects maintain docs.
5. Write your assessment

## Output

Write `.ah/check/check.md`:

    # Check

    ## Plan compliance
    <did changes match plan?>

    ## Validation
    <results of running validation steps>

    ## Issues
    <problems found, grouped by severity>

    ### Critical
    <blocks merge, must fix. include file path and line number.>

    ### Warnings
    <should fix, not blocking. include file path and line number.>

    ### Suggestions
    <optional improvements>

    (write "none" for empty sections)

    ## Verdict
    <pass|needs-fixes|fail>

Write `.ah/check/actions.json`:

    {
      "verdict": "pass|needs-fixes|fail",
      "actions": [
        {"action": "comment_issue", "body": "..."},
        {"action": "create_pr", "branch": "...", "title": "...", "body": "..."}
      ]
    }

Action rules:
- Always include `comment_issue` with verdict and summary
- Include `create_pr` only when verdict is "pass" and changes were committed

Write `.ah/check/update.md`: 2-4 line summary.

If verdict is "needs-fixes", copy the critical and warning issues into
`.ah/do/feedback.md` so the do phase can address them on re-run.
If verdict is "pass" or "fail", do NOT write `.ah/do/feedback.md`.

Do NOT modify any source files.

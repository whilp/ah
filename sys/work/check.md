# Check

You are checking a work item. Review the execution against the plan.

## Plan

{plan.md contents}

## Execution summary

{do.md contents}

## Instructions

1. Review the diff: `git diff main...HEAD`
2. Run validation steps from the plan
3. Check for unintended changes
4. Write your assessment

## Output

Write `o/work/check/check.md`:

    # Check

    ## Plan compliance
    <did changes match plan?>

    ## Validation
    <results of running validation steps>

    ## Issues
    <problems found, or "none">

    ## Verdict
    <pass|needs-fixes|fail>

Write `o/work/check/actions.json`:

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

Write `o/work/check/update.md`: 2-4 line summary.

Do NOT modify any source files.
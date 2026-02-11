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

    ## Friction
    <what slowed this work down or caused errors? examples:
     hallucinated facts not verified against source, missing validation
     in plan, unclear requirements, tool failures, prompt gaps.
     write "none" if the work was smooth.>

    ## Verdict
    <pass|needs-fixes|fail>

Write `o/work/check/actions.json`:

    {
      "verdict": "pass|needs-fixes|fail",
      "friction": ["<friction item>", ...],
      "actions": [
        {"action": "comment_issue", "body": "..."},
        {"action": "create_pr", "branch": "...", "title": "...", "body": "..."}
      ]
    }

Action rules:
- Always include `comment_issue` with verdict, summary, and any friction items
- Include `create_pr` only when verdict is "pass" and changes were committed
- `friction` array: one short string per friction item, or empty array if none

Write `o/work/check/update.md`: 2-4 line summary.

Do NOT modify any source files.
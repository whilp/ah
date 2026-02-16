---
name: triage-issues
description: Triage open GitHub issues. Assess priority, deduplicate, label, close stale issues, break down oversized issues, and refine underspecified issues.
---

# triage-issues

Triage open issues in the repo. Assess priority, deduplicate, apply labels,
break down oversized issues, and refine underspecified issues.

## Usage

```
/skill:triage-issues [--label <filter>] [--limit <n>]
```

## Steps

1. **Fetch open issues**
   ```bash
   gh issue list --state open --limit 50 --json number,title,body,labels,createdAt,updatedAt,comments
   ```
   If `--label` was provided, add `--label <filter>` to the command.
   If `--limit` was provided, use that instead of 50.

2. **For each issue, assess:**
   - **actionability**: is the problem clear? can it be worked on now?
   - **priority**: p0 (critical/blocking), p1 (high/impactful), p2 (low/minor)
   - **size**: can it be completed in a short session (~50 tool calls)?
     an issue is too big if it touches 4+ files across subsystems, requires
     a design decision between multiple approaches, or bundles independent
     concerns.
   - **duplicates**: does it overlap with another open issue?
   - **staleness**: is it outdated or already resolved by recent changes?
   - **labels**: which labels should be added or removed?
   - **specificity**: is the body detailed enough to act on? does it identify
     files, functions, root causes, and a concrete approach?

3. **Check for duplicates** by reading bodies of related issues:
   ```bash
   gh issue view <number> --json body,comments
   ```

4. **Print triage summary table** before taking any action:

   ```
   | # | title | labels | size | action | reason |
   |---|-------|--------|------|--------|--------|
   ```

   size values: small, medium, too big, too vague.
   actions: keep, close, break down, refine, add labels.

5. **Present each recommended action one at a time** and wait for user
   approval before executing. this prevents unwanted bulk changes and lets
   the user redirect (e.g. cancel instead of break down, skip instead of
   refine).

6. **Apply triage decisions** after approval:
   ```bash
   # add priority label
   gh issue edit <number> --add-label "p1"

   # close duplicate, referencing the canonical issue
   gh issue close <number> --comment "duplicate of #<canonical>"

   # close stale/resolved issues
   gh issue close <number> --comment "resolved — <reason>"

   # close issues that aren't worth the complexity
   gh issue close <number> --comment "closing — <reason>"

   # flag issues needing more context
   gh issue edit <number> --add-label "needs-investigation"
   ```

7. **Break down oversized issues** — for issues that are too big for a
   short session, create focused sub-issues:

   - each sub-issue should be independently shippable and testable
   - include a `## Parent` section referencing the original issue
   - specify concrete files to modify and constraints
   - note dependencies between sub-issues if any
   - comment on the parent issue linking all sub-issues
   - keep the parent open as a tracker, or close it if fully replaced

   ```bash
   gh issue create --title "<focused title>" --label "todo" \
     --body "<scoped body with Parent reference>"
   gh issue comment <parent> --body "broken down into: #A, #B, #C"
   ```

8. **Refine one underspecified issue** — pick the thinnest issue that is
   still open and actionable. Research the codebase to fill in specifics:

   - read source files referenced or implied by the issue
   - identify current state, file paths, line numbers
   - write a concrete proposed approach
   - update the issue body:
     ```bash
     gh issue edit <number> --body "<refined body>"
     ```

   Do only one refinement per triage run. Skip refinement for issues where
   the planner can reasonably fill in the gaps from a vague description.

## Priority criteria

- **p0**: blocks the work workflow, causes data loss, or breaks core functionality
- **p1**: significant friction affecting most runs, clear fix path
- **p2**: minor annoyance, cosmetic, or rare edge case
- enhancements get no priority label unless urgent

## Output

After all actions, print a summary of what was done:

```
| action | issue | detail |
|--------|-------|--------|
| created | #285 | sub-issue of #253: gate proxy logging |
| closed | #211 | cancelled — too complex for the value |
```

## Rules

- do not close issues unless clearly duplicate, resolved, or not worth the
  complexity — when in doubt, keep open
- always comment before closing, citing the reason
- if an issue lacks enough context to triage, label it `needs-investigation`
- prefer merging duplicates into the older or more-detailed issue
- present actions to the user for approval before executing

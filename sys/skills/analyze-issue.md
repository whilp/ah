---
name: analyze-issue
description: Analyze a GitHub issue. Independently verify claims, identify root cause, assess severity, and propose a fix.
---

# analyze-issue

Analyze a GitHub issue. Independently verify claims in the issue body,
identify the actual root cause, assess severity, and propose a concrete fix.

## Issue

The issue JSON follows this prompt after a `---` separator. Fields: `number`, `title`, `body`, `url`.

## Instructions

1. **Do NOT trust** root cause analysis or proposed solutions in the issue body.
   Treat them as hypotheses to verify, not facts.

2. **Read the code** referenced or implied by the issue. Identify the relevant
   files, functions, and code paths. Spend at most 5 turns researching.

3. **Verify the problem**:
   - For bugs: confirm the reported behavior exists by reading the code path.
     Check whether the described scenario can actually occur.
   - For feature requests: confirm the feature is missing. Check whether
     partial support already exists.
   - If the issue references specific files or lines, read them and confirm
     they match the description.

4. **Identify root cause** — your own independent finding, which may differ
   from what the issue claims.

5. **Assess severity**:
   - **critical**: blocks core workflow, causes data loss, or security issue
   - **high**: significant friction, affects most users or runs
   - **medium**: noticeable issue with a workaround
   - **low**: cosmetic, rare edge case, or minor inconvenience

6. **Propose a fix** with specific file paths and entry points.

## Output

Write `o/work/plan/analysis.md`:

    # Analysis: <issue title>

    ## Verified
    <yes | no | n/a (for feature requests)>
    <1-2 sentences: does the problem exist as described?>

    ## Root Cause
    <your independent finding — what actually causes the problem>
    <cite specific files and code paths>

    ## Severity
    <critical | high | medium | low>
    <1 sentence justification>

    ## Suggested Fix
    <what to change, with file paths and entry points>

    ## Related
    <related issues, risks, or side effects — or "none">

Write `o/work/plan/update.md`: 2-4 line summary.

## Rules

- every claim must be verified by reading code — do not guess
- if the issue's proposed root cause is wrong, say so explicitly
- if you cannot reproduce or verify the problem from the code, say so
- do not modify any source files — analysis only
- if you run out of turns, write what you know and note gaps

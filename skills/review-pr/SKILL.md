---
name: review-pr
description: Review an incoming pull request. Read the diff, check linked issues, analyze for correctness and security, write a structured assessment.
---

# review-pr

Review an incoming pull request. Analyze the diff, check linked issues,
and provide a structured good/bad/ugly assessment.

## Usage

```
/skill:review-pr <number>
```

## Steps

1. **Read the PR metadata**
   ```bash
   gh pr view <number> --json title,body,headRefName,baseRefName,additions,deletions,files,comments,reviews
   ```

2. **Read linked issues** referenced in the PR body or title (`#NNN`):
   ```bash
   gh issue view <issue-number> --json title,body,labels
   ```
   Understand the motivation and acceptance criteria.

3. **Read the diff**
   ```bash
   gh pr diff <number>
   ```
   For large diffs (>2000 lines), focus on non-test source files first.
   Read generated or vendored files last, if at all.

4. **Read changed files in full** for context around the diff:
   ```bash
   gh pr view <number> --json files --jq '.files[].path'
   ```
   Read each changed file to understand the surrounding code.

5. **Analyze changes** — check each of these:
   - **correctness**: does the code do what the issue asks? are edge cases handled?
   - **regressions**: could this break existing behavior?
   - **security**: injection, path traversal, secrets, unsafe input handling
   - **error handling**: are errors checked and propagated?
   - **concurrency**: races, deadlocks, unsafe shared state
   - **style**: consistency with surrounding code, naming, structure

6. **Check docs and changelog** — if the PR changes behavior or adds features:
   - are relevant docs updated?
   - is CHANGELOG or equivalent updated?
   - are new flags/options documented?

7. **Write the assessment** (see Output below)

8. **Optionally submit the review** — only if the user explicitly asks:
   ```bash
   gh pr review <number> --approve --body "<summary>"
   gh pr review <number> --request-changes --body "<summary>"
   gh pr review <number> --comment --body "<summary>"
   ```
   Default to `--comment`. Never use `--approve` or `--request-changes`
   without user confirmation.

## Output

Print the review:

```
## Review: PR #<number> — <title>

### Summary
<1-3 sentences: what the PR does and whether it achieves its goal>

### Good
- <things done well, good patterns, solid coverage>

### Bad
- <issues that should be fixed before merge>

### Ugly
- <concerns, risks, things to watch — not necessarily blockers>

### Verdict
<approve | request-changes | comment>
<1 sentence justification>
```

## Rules

- cite specific files and line numbers when pointing out issues
- verify claims by reading the code — do not guess
- do not nitpick formatting or style unless it harms readability
- treat test coverage gaps as "bad" only if the change is risky
- if the diff is too large to review fully, state which parts were skipped
- never approve or request changes without user confirmation

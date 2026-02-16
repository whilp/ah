---
name: pr
description: Open a pull request, resolve merge conflicts, watch CI, or review an incoming PR.
---

# pr

two modes: **open** (default) and **review**.

## open mode

`/skill:pr` — open a PR for the current branch, resolve conflicts, watch CI.

1. **identify branch and target**
   ```bash
   git branch --show-current
   git log --oneline main..HEAD
   ```

2. **open the PR** (or find existing one)
   ```bash
   gh pr create --fill --base main
   gh pr view --json number,url,state  # if already exists
   ```

3. **resolve merge conflicts** if any:
   ```bash
   gh pr view --json mergeable,mergeStateStatus
   git fetch origin main && git rebase origin/main
   # resolve, git add, git rebase --continue
   git push --force-with-lease
   ```

4. **watch CI** until complete:
   ```bash
   gh pr checks --watch --fail-fast
   ```

5. **handle failures** — read logs, fix, push, repeat:
   ```bash
   gh run view <run-id> --log-failed
   ```

### output

write `o/work/pr/pr.md` with url, conflict status, check status, notes.
write `o/work/pr/update.md` with 2-4 line summary.

## review mode

`/skill:pr <number>` — review an incoming PR.

1. **read metadata and linked issues**
   ```bash
   gh pr view <number> --json title,body,headRefName,baseRefName,additions,deletions,files,comments,reviews
   gh issue view <issue-number> --json title,body,labels  # for each linked issue
   ```

2. **read the diff** (for large diffs, prioritize non-test source files)
   ```bash
   gh pr diff <number>
   ```

3. **read changed files in full** for surrounding context.

4. **analyze** — check for: correctness, regressions, security, error
   handling, concurrency issues, style consistency.

5. **check docs** — are docs/changelog updated if behavior changed?

6. **submit review** only if user explicitly asks. default to `--comment`.
   never `--approve` or `--request-changes` without confirmation.
   ```bash
   gh pr review <number> --comment --body "<summary>"
   ```

### output

```
## Review: PR #<number> — <title>

### Summary
<1-3 sentences>

### Good
- <things done well>

### Bad
- <issues to fix before merge>

### Ugly
- <concerns, not necessarily blockers>

### Verdict
<approve | request-changes | comment> — <1 sentence justification>
```

## rules

- cite specific files and line numbers
- verify claims by reading code — do not guess
- do not nitpick style unless it harms readability
- if the diff is too large to fully review, state what was skipped

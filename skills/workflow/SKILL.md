---
name: workflow
description: Trigger a GitHub Actions workflow, watch it, and if it fails, analyze logs, debug, fix on a new branch via red-green TDD, and open a PR.
---

# workflow

Trigger a GitHub Actions workflow run, watch it to completion, and react to
the result. On success, verify the run is genuine. On failure, analyze logs,
identify the root cause, fix it on a new branch with tests, and open a PR.

## Usage

```
/skill:workflow <workflow-name> [--ref <branch>]
```

Default ref is `main`.

## Steps

### 1. Trigger the workflow

```bash
gh workflow run <workflow-name> --ref <branch>
```

Wait a few seconds, then find the new run:

```bash
sleep 5
gh run list --workflow <workflow-name>.yml -L 3
```

Capture the run ID of the `in_progress` (or most recent) run.

### 2. Watch the run

```bash
gh run watch <run-id> --exit-status
```

This blocks until the run completes. Use a generous timeout (10 minutes).

### 3. On success

If the run passed, verify it's genuine:

```bash
gh run view <run-id> --json conclusion,jobs
```

Confirm all jobs show `conclusion: success`. Check annotations for warnings.
Report the result and stop.

### 4. On failure — analyze logs

Get the full logs and extract error signals:

```bash
# Full log for the failed run
gh run view <run-id> --log-failed

# Search for error patterns
gh run view <run-id> --log 2>&1 | grep -E "(Error|error|FAIL|fatal|panic)" | head -30

# Check annotations
gh run view <run-id> --json jobs --jq '.jobs[].steps[] | select(.conclusion == "failure") | {name, conclusion}'
```

Read the failing step's output carefully. Identify:
- **What failed**: which step, what command, what error message
- **Why it failed**: root cause in the codebase (not just the symptom)

### 5. On failure — find the root cause

Trace the error back to source code:

1. Read the workflow YAML to understand what commands run:
   ```bash
   gh workflow view <workflow-name> --yaml
   ```

2. Read the Makefile targets invoked by the workflow:
   ```bash
   # e.g., if workflow runs `make work`, read work.mk
   ```

3. Read the source files involved in the failure. Use `grep` to find
   relevant code paths. Read each file before forming a hypothesis.

4. **Reproduce locally if possible** — run the failing command or a
   minimal reproduction to confirm the hypothesis.

### 6. On failure — fix via red-green TDD

Load the `worktree` skill (`skill(name="worktree")`) and use it to create
an isolated worktree with branch `fix/<slug>`.

Inside the worktree:

#### RED: write a failing test first

Add a test that exercises the broken behavior. Run the test suite and
confirm the new test fails:

```bash
make test 2>&1 | grep -E "FAIL|PASS"
```

The test must fail for the right reason — the same root cause as the
workflow failure.

#### GREEN: implement the fix

Make the minimal code change to fix the root cause. Run the full test
suite and confirm everything passes:

```bash
make test
```

#### Commit and push

```bash
git add <changed files>   # stage specific files, not git add -A
git commit -m "<descriptive message explaining the fix>"
git push -u origin fix/<slug>
```

### 7. Open a PR

Load the `pr` skill (`skill(name="pr")`) and use it to open a PR,
watch CI, and handle failures.

### 8. Clean up

Report the final state. Offer to remove the worktree (the `worktree`
skill covers cleanup).

## Output

Print a summary:

```
## Workflow: <name>

### Run
- ID: <run-id>
- Result: <success|failure>
- URL: <run-url>

### Root cause (if failure)
<one paragraph explaining what broke and why>

### Fix (if failure)
- Branch: fix/<slug>
- PR: <pr-url>
- CI: <pass|fail|pending>

### Files changed
- <path> — <what changed>
```

## Rules

- always read source files before editing them
- never guess at APIs or interfaces — verify by reading code or running commands
- write tests before fixes (red-green)
- stage specific files, not `git add -A`
- one logical fix per commit; don't bundle unrelated changes
- if the failure is an infrastructure/transient issue (e.g., network timeout
  not caused by code), report it and stop — don't create a branch
- use worktrees for fixes to keep the main working directory clean
- set generous timeouts when watching runs (10 minutes)

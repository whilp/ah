---
name: prerelease
description: Build ah and create a GitHub prerelease with the binary and checksums.
---

# prerelease

Trigger the `release.yml` GitHub Actions workflow, watch it, and verify
the release was created.

## Steps

### 1. Trigger the workflow

Default is prerelease. If the user asks for a full release, pass
`-f release=true`.

```bash
gh workflow run release.yml --ref main
# full release:
gh workflow run release.yml --ref main -f release=true
```

### 2. Find the run

Wait a few seconds, then locate the in-progress run:

```bash
sleep 5
gh run list --workflow release.yml -L 3
```

Capture the run ID of the most recent run.

### 3. Watch the run

Poll until the run completes, tailing log output each iteration for incremental visibility:

```bash
while true; do
  status=$(gh run view <run-id> --json status -q .status)
  gh run view <run-id> --log 2>/dev/null | tail -20
  if [ "$status" != "in_progress" ] && [ "$status" != "queued" ]; then
    break
  fi
  sleep 10
done
conclusion=$(gh run view <run-id> --json conclusion -q .conclusion)
echo "Run concluded: $conclusion"
```

If `conclusion` is not `success`, treat the run as failed (proceed to step 4).

### 4. Handle failure

If the run fails, inspect logs:

```bash
gh run view <run-id> --log-failed
```

Report the error and stop.

### 5. Verify the release

```bash
gh release list --limit 1
gh release view <tag>
```

## Output

Print a summary:

```
## Prerelease: <tag>

- run: <run-id>
- tag: <tag>
- artifacts: ah, ah-debug, SHA256SUMS
- url: <release-url>
```

## Rules

- default to prerelease unless the user explicitly says "full release"
- always watch the run to completion — do not fire and forget
- if the workflow fails, show the failed logs and stop

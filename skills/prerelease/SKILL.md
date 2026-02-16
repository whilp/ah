---
name: prerelease
description: Build ah and create a GitHub prerelease with the binary and checksums.
---

# prerelease

Build the `ah` binary and publish a GitHub prerelease. Mirrors the
`.github/workflows/prerelease.yml` workflow but runs locally.

## Steps

### 1. Build

```bash
make -j ah
```

### 2. Generate checksums

```bash
cd o/bin && sha256sum ah > SHA256SUMS
```

### 3. Determine tag

Tag format is `YYYY-MM-DD-<short-sha>`:

```bash
TAG="$(date -u +%Y-%m-%d)-$(git rev-parse --short HEAD)"
```

### 4. Create the release

Delete any existing release with the same tag, then create:

```bash
gh release delete "$TAG" --yes 2>/dev/null || true
gh release create "$TAG" \
  --title "$TAG" \
  --prerelease \
  --generate-notes \
  --target "$(git branch --show-current)" \
  o/bin/ah \
  o/bin/SHA256SUMS
```

Use `--target` set to the current branch (usually `main`).

### 5. Verify

```bash
gh release view "$TAG"
```

## Full release

If the user asks for a full (non-pre) release, omit `--prerelease`:

```bash
gh release create "$TAG" \
  --title "$TAG" \
  --generate-notes \
  --target "$(git branch --show-current)" \
  o/bin/ah \
  o/bin/SHA256SUMS
```

## Output

Print a summary:

```
## Prerelease: <tag>

- tag: <tag>
- target: <branch> (<sha>)
- artifacts: ah, SHA256SUMS
- url: <release-url>
```

## Rules

- always run `make -j ah` fresh — do not reuse stale builds
- include SHA256SUMS alongside the binary
- default to prerelease unless the user explicitly says "full release"
- if `gh release create` fails, show the error and stop

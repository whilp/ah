---
name: setup-work
description: Bootstrap ah work loop in a new repository. Generate workflows, Makefile, and CLAUDE.md from ah's own CI files.
---

# Setup Work

Configure a repository for ah's automated work loop.

## What this skill does

Generates the files needed to run `make work` in a repository:
- `.github/workflows/work.yml` — scheduled workflow that runs `make work`
- `.github/workflows/test.yml` — CI workflow for tests and linting
- `Makefile` — build system with ah download, work loop, and repo-specific targets
- `work.mk` — PDCA work loop targets (used as-is)
- `CLAUDE.md` — project context for the agent

## Instructions

### 1. Analyze the repository

Read files to detect:
- **Language**: file extensions, package files (package.json, go.mod, Cargo.toml, pyproject.toml, etc.)
- **Build system**: existing Makefile, npm scripts, cargo, gradle, etc.
- **Test framework**: what test runner is used, how tests are invoked
- **Linter**: eslint, golangci-lint, clippy, ruff, etc.
- **Existing CI**: check `.github/workflows/`, `.circleci/`, `.travis.yml`

If the repo already has CI, note what exists and only generate what's missing.

### 2. Read the reference files

The ah binary embeds the exact CI files that ah itself uses. Read all of them:

- `/zip/embed/ci/Makefile` — ah's own Makefile
- `/zip/embed/ci/work.mk` — ah's own work loop targets
- `/zip/embed/ci/.github/workflows/work.yml` — ah's own work workflow
- `/zip/embed/ci/.github/workflows/test.yml` — ah's own test workflow
- `/zip/embed/ci/lib/work/work.tl` — ah's own work pipeline script

These are the source of truth. Study how they work together:
- `Makefile` includes `work.mk` via `include work.mk`
- `work.mk` defines the PDCA loop (plan → do → push → check → act)
- `work.mk` invokes `lib/work/work.tl` for pipeline subcommands (labels, issues, issue, doing, act)
- `work.yml` runs `make ah && make work` on a schedule
- `test.yml` runs `make -j ci` on push/PR

### 3. Generate files

> **Note:** `/zip/` paths are virtual — use the `read` tool to access them,
> then `write` to create copies. Bash commands like `cp` and `ls` cannot
> access `/zip/`.

#### `work.mk` — copy verbatim

Copy `/zip/embed/ci/work.mk` to `work.mk` in the target repo. This file
is repo-agnostic and should be used as-is. Do not modify it.

#### `lib/work/work.tl` — copy verbatim

Copy `/zip/embed/ci/lib/work/work.tl` to `lib/work/work.tl` in the target
repo. This script is invoked by `work.mk` for pipeline subcommands (labels,
issues, issue, doing, act). Use as-is.

#### `Makefile` — adapt to the target repo

Use `/zip/embed/ci/Makefile` as the reference. The target repo's Makefile needs:

1. **Standard preamble**: `SHELL`, `.SHELLFLAGS`, `MAKEFLAGS`, `o` variable
2. **ah binary download**: instead of building from source, download the
   prebuilt binary from GitHub releases. get the latest version and sha from
   https://github.com/whilp/ah/releases. the target should produce `$(o)/bin/ah`.
3. **Repo-specific targets**: `test`, `build`, `ci`, `lint` — adapted to the
   repo's actual language and tooling
4. **`include work.mk`** at the end
5. **`clean` and `help`** targets

If a Makefile already exists, integrate the ah targets into it rather than
replacing it. The critical parts are the ah download target and `include work.mk`.

#### `.github/workflows/work.yml` — adapt

Use `/zip/embed/ci/.github/workflows/work.yml` as the reference. Key adaptations:

- Replace `make ah` with the ah download step (curl + sha256sum + chmod)
- Keep the same structure: checkout with fetch-depth 0, env vars, permissions,
  concurrency group, artifact upload
- The run step should be `make work` (work.mk handles everything)
- Keep `CLAUDE_CODE_OAUTH_TOKEN` secret reference
- Keep `DEFAULT_BRANCH` env var

#### `.github/workflows/test.yml` — adapt

Use `/zip/embed/ci/.github/workflows/test.yml` as the reference. Adapt:

- Add language-specific setup steps (setup-node, setup-python, setup-go, etc.)
- The run command should match the repo's `make ci` target

#### `CLAUDE.md` — generate

Create a CLAUDE.md with:
- Project name and description
- Build, test, and lint commands (`make build`, `make test`, `make ci`)
- Architecture overview (key directories and their purpose)
- Development conventions (branch naming, commit style)

If a CLAUDE.md already exists, enhance it rather than overwrite.

### 4. Validate

After generating files:
- Verify Makefile syntax: `make -n work` (dry run)
- Check that `work.mk` is identical to the reference: `diff work.mk <(ah extract /zip/embed/ci/work.mk)` or just verify by reading

### 5. Tell the user what to do next

1. Add `CLAUDE_CODE_OAUTH_TOKEN` secret to the repository
   (Settings → Secrets → Actions → New repository secret)
2. Review and commit the generated files
3. Create issues labeled `work` for ah to pick up
4. The work workflow runs every 3 hours (or trigger manually via workflow_dispatch)

## Important notes

- `work.mk` is the heart of the system. It should be used verbatim.
- The Makefile is repo-specific. Only the preamble, ah download, and
  `include work.mk` are required from the ah side.
- `ah` is a self-contained binary. Download it from releases; do not build
  from source in other repos.
- The work loop is language-agnostic. It works with any language or framework.

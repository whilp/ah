---
name: init
description: Generate agent-friendly documentation for a repository. Produce a short index file and deeper docs it points to.
---

# Init

Generate agent-friendly documentation for a repository. the output is a
short index file (`CLAUDE.md` or `AGENTS.md`) that serves as a table of
contents, plus deeper docs it points to.

## Principles

**a map, not a manual.** the index file is loaded into every agent
session's system prompt. it must be short (~100 lines). a giant file
crowds out the task and the code — context is scarce. when everything is
"important," agents pattern-match locally instead of navigating
intentionally.

**progressive disclosure.** the index tells agents where to look. deeper
docs (`docs/`, `ARCHITECTURE.md`, inline comments) provide detail. agents
load them with `read` when needed. don't inline what can be pointed to.

**repository as system of record.** anything the agent can't access
in-context effectively doesn't exist. knowledge in chat threads, wikis,
or people's heads is invisible. push it into the repo as versioned
markdown.

## Instructions

### 1. Analyze the repository

Read files to understand the project. Spend at most 8 tool calls.

**Detect:**
- language and framework (file extensions, package files, imports)
- build system (Makefile, package.json scripts, Cargo.toml, pyproject.toml)
- test framework and how to run tests
- linter/formatter and how to run it
- directory structure and what each top-level directory contains
- key abstractions (models, services, handlers, routes, etc.)
- entry points (main, bin, cmd)
- existing docs (README.md, docs/, ARCHITECTURE.md, CLAUDE.md, AGENTS.md)

```bash
find . -maxdepth 2 -type f -not -path './.git/*' -not -path './node_modules/*' -not -path './vendor/*' -not -path './.venv/*' | head -80
```

### 2. Choose the filename

- if a `CLAUDE.md` already exists, update it in place.
- if an `AGENTS.md` already exists (no `CLAUDE.md`), update it in place.
- if neither exists, create `AGENTS.md`.
- never create both. one file.

### 3. Write the index file

The index file is short and points elsewhere. use this structure:

```markdown
# <project name>

<one-line description>

## build

<exact commands: build, test, lint, format, single-test>

## structure

<top-level directories, one line each>
<key files and their roles>

## docs

pointers to deeper documentation. each entry is a path the agent can
`read` when it needs that context:

- `docs/architecture.md` — system layers, data flow, boundaries
- `docs/conventions.md` — naming, error handling, commit format
- `docs/<topic>.md` — ...

## making changes

<short checklist: what to do before, during, and after editing>
<what validation to run>
```

The `## docs` section is the heart of the index. every pointer is a real
file path that the agent can load. if a doc doesn't exist yet, create it.

### 4. Write the deeper docs

Create the files the index points to. at minimum:

**`docs/architecture.md`** — how the system is organized:
- layers, modules, domains
- key abstractions and where they live
- entry points
- boundaries: what depends on what, what's off-limits
- data flow for the main operations

**`docs/conventions.md`** — how code is written here:
- language idioms, naming patterns
- error handling style
- testing patterns (unit, integration, what to mock)
- commit message format if enforced
- branch naming if relevant

Create additional `docs/<topic>.md` files if the codebase has distinct
areas that deserve their own reference (API contracts, database schema,
deployment, etc.). keep each doc focused — one topic per file.

### 5. Style guide

Apply to all generated docs:

- **short declarative sentences.** no filler, no preamble.
- **concrete over abstract.** file paths, command lines, exact names.
- **commands must be copy-pasteable.** test them with `bash` if unsure.
- **prefer boring.** document well-understood tools and patterns. agents
  reason better about things with broad training-set coverage.
- **write for freshness.** avoid specifics that rot (exact line numbers,
  transient counts, version numbers). prefer stable references: file
  paths, function names, directory structure.
- **match the codebase voice.** if the project uses lowercase everywhere,
  write lowercase.

### 6. Validate

Verify the build/test commands actually work:

```bash
# run whatever build command you documented
# run whatever test command you documented
```

If a command fails, fix the docs (not the project).

### 7. Handle existing docs

- **existing index file**: read it first. preserve project-specific
  context that's still accurate. restructure to match the template.
- **existing docs/**: read them. update rather than replace. fill gaps.
- **stale content**: remove it. stale rules are worse than no rules —
  agents can't tell what's still true.

## Output

Write the index file and all `docs/*.md` files it references.

List what you created in your response so the user can review and commit.

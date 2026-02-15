---
name: init
description: Generate a CLAUDE.md for a repository. Analyze the codebase and produce agent-friendly documentation.
---

# Init

Generate a `CLAUDE.md` that makes a repository legible to coding agents.

## Why CLAUDE.md

`CLAUDE.md` is loaded into the system prompt at the start of every session.
it gives the agent a map of the codebase so it can navigate without
guessing. a good CLAUDE.md eliminates the most common failure mode:
the agent doesn't know where things are or how they fit together.

## Instructions

### 1. Analyze the repository

Read files to understand the project. Spend at most 8 tool calls on this.

**Detect:**
- language and framework (file extensions, package files, imports)
- build system (Makefile, package.json scripts, Cargo.toml, pyproject.toml)
- test framework and how to run tests
- linter/formatter and how to run it
- directory structure and what each top-level directory contains
- key abstractions (models, services, handlers, routes, etc.)
- entry points (main, bin, cmd)

**Read these files if they exist:**
- `README.md` — project description
- `Makefile` or build config — build/test/lint commands
- `package.json`, `go.mod`, `Cargo.toml`, `pyproject.toml` — dependencies
- `.github/workflows/*.yml` — CI configuration
- existing `CLAUDE.md` or `AGENTS.md` — prior agent docs

```bash
find . -maxdepth 2 -type f -not -path './.git/*' -not -path './node_modules/*' -not -path './vendor/*' -not -path './.venv/*' | head -80
```

### 2. Write CLAUDE.md

Write `CLAUDE.md` in the repository root. Use this structure:

```markdown
# <project name>

<one-line description of what this project does>

## build

<exact commands to build, test, lint, format>
<include the single-test command if the framework supports it>

## structure

<top-level directories and what they contain>
<key files and their roles>

## architecture

<how the system is organized: layers, modules, data flow>
<key abstractions and where they live>
<entry points>

## conventions

<language idioms, naming patterns, error handling style>
<commit message format if enforced>
<branch naming if relevant>

## making changes

<step-by-step: what to do before, during, and after editing code>
<what validation to run>
<what to watch out for>
```

### 3. Style guide

Follow these rules when writing CLAUDE.md:

- **short declarative sentences.** no filler, no preamble.
- **concrete over abstract.** file paths, command lines, exact names.
- **commands must be copy-pasteable.** test them with `bash` if unsure.
- **progressive disclosure.** start with what the agent needs most
  (build commands, structure), then add depth (architecture, conventions).
- **one page.** aim for 80–150 lines. if it's longer, cut the least
  important sections. a long CLAUDE.md crowds out the actual task.
- **no redundancy.** don't repeat what's obvious from filenames or
  standard framework conventions.
- **use the same voice as the codebase.** if the project uses lowercase
  everywhere, write lowercase. match the existing tone.

### 4. Validate

After writing, verify the build/test commands actually work:

```bash
# run whatever build command you documented
# run whatever test command you documented
```

If a command fails, fix the CLAUDE.md (not the project).

### 5. Handle existing files

- **existing CLAUDE.md**: read it first. preserve project-specific
  context that's still accurate. rewrite the structure to match the
  template above. don't blindly append.
- **existing AGENTS.md**: read it. if CLAUDE.md doesn't exist, rename
  AGENTS.md to CLAUDE.md and rewrite to match the template. if both
  exist, merge into CLAUDE.md and delete AGENTS.md (CLAUDE.md
  supersedes AGENTS.md).

## Output

Write `CLAUDE.md` in the repository root.

If you renamed or merged AGENTS.md, note that in your response so the
user can commit the deletion.

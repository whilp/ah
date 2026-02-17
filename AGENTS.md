# AGENTS.md

agent-first documentation for working in this repository. read this before
making changes.

## quick reference

```sh
make ci            # run tests + type checks (canonical validation command)
make test          # run tests only
make check-types   # type checks only
make build         # compile .tl → .lua
make ah            # build executable
make release       # create GitHub prerelease (RELEASE=1 for full)
```

use `make ci` as the default validation command after changes.

## what ah is

ah is a minimal agent harness. it manages the lifecycle of an LLM agent
session: prompt → API call → tool execution → loop. it provides session
persistence, conversation branching, sandboxed execution, and context
compaction.

ah is written in [teal](https://github.com/teal-language/tl) (typed lua),
compiled to lua, and embedded into a single executable via
[cosmic](https://github.com/whilp/cosmic). the executable is a
self-contained zip archive containing lua modules, system prompts, skill
files, and CI reference files.

## docs index

detailed documentation lives in `docs/`. read the relevant file before
working in that area.

| file | covers |
|------|--------|
| [docs/design.md](docs/design.md) | design principles and philosophy |
| [docs/architecture.md](docs/architecture.md) | module map, data flow, build system, embedding |
| [docs/agent-loop.md](docs/agent-loop.md) | API call cycle, tool dispatch, loop detection, compaction, streaming |
| [docs/session.md](docs/session.md) | database schema, conversation tree, branching, session resolution |
| [docs/tools.md](docs/tools.md) | tool loading, tiers, overrides, custom tools, truncation |
| [docs/skills.md](docs/skills.md) | skill format, loading, expansion, system prompt injection |
| [docs/sandbox.md](docs/sandbox.md) | network proxy, unveil, pledge, `--sandbox` mode |
| [docs/testing.md](docs/testing.md) | test conventions, running tests, adding new tests |

## project layout

```
bin/ah.tl              CLI entry point
lib/ah/                core modules
  init.tl              CLI parsing, session management, prompt loading
  loop.tl              agent loop (API call → tool dispatch → repeat)
  api.tl               Claude Messages API client with streaming
  db.tl                SQLite conversation storage
  tools.tl             tool loading, dispatch, and prompt generation
  skills.tl            skill loading and /skill: expansion
  commands.tl          /command expansion
  compact.tl           context window compaction
  truncate.tl          tool output truncation for API
  sandbox.tl           sandbox supervisor (proxy lifecycle, child env)
  queue.tl             inter-process steering/followup queue
  proxy.tl             HTTP CONNECT proxy for sandbox
  auth.tl              credential loading (API key / OAuth)
  events.tl            structured lifecycle events
lib/ulid.tl            ULID generation/parsing
sys/system.md          default system prompt
sys/tools/             built-in tool definitions (.tl, compiled to .lua)
  read.tl              file reading with image support
  write.tl             file writing with directory creation
  edit.tl              find-and-replace with uniqueness check
  bash.tl              command execution with timeout and abort
sys/skills/            built-in skill files
Makefile               build system
```

## conventions

- **language**: teal (typed lua). all source is `.tl`, compiled to `.lua` in `o/`.
- **tests**: `lib/ah/test_*.tl` and `lib/ah/work/test_*.tl`. each test file
  is a standalone script run by cosmic. tests print "PASS" or "FAIL" lines.
- **validation**: always run `make ci` before committing. it runs tests and
  type checks in parallel.
- **build output**: everything goes under `o/`. never commit `o/`.
- **cosmic dependency**: cosmic is pinned by URL and sha256 in `deps/cosmic.mk`,
  included by the Makefile. binaries depend on the `.mk` file — changing it
  triggers re-fetch.
- **releasing**: `make release` creates a GitHub prerelease (`RELEASE=1` for
  full). `.github/workflows/release.yml` runs daily and on manual dispatch.
- **project context**: ah reads `CLAUDE.md` or `AGENTS.md` from the working
  directory and appends it to the system prompt. `CLAUDE.md` takes precedence.
- **credentials**: set `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`.
  ah also reads `.env` files. credentials can be embedded via `env.d/`
  (see below).
- **env.d**: embed environment variables into the executable. create a
  directory with `KEY=VALUE` files (`.env` format), then `ah embed <dir>`
  where `<dir>` contains an `env.d/` subdirectory. on startup, ah loads
  all files from `/zip/embed/env.d/` and sets variables that aren't already
  in the environment. real env vars always take precedence.
  ```sh
  mkdir -p myconfig/env.d
  echo 'ANTHROPIC_API_KEY=sk-ant-...' > myconfig/env.d/auth.env
  ah embed myconfig
  ```
- **models**: aliases `sonnet`, `opus`, `haiku` resolve to full model names
  in `api.tl`. default model is `claude-opus-4-6`.
- **accessibility**: terminal colors must be colorblind-friendly. avoid
  red/green distinctions — use blue/yellow or bold/dim instead. all visual
  indicators should be distinguishable without color (e.g. via shape, symbol,
  or text). test color choices against common forms of color vision deficiency
  (deuteranopia, protanopia, tritanopia).

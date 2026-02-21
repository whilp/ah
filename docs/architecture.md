# architecture

## module dependency graph

```
bin/ah.tl → lib/ah/init.tl (CLI, session management)
  ├── loop.tl (agent loop)
  │   ├── api.tl (Claude Messages API, streaming, retries)
  │   ├── tools.tl (tool loading, dispatch, prompt generation)
  │   ├── compact.tl (context window compaction)
  │   ├── truncate.tl (tool output truncation)
  │   ├── queue.tl (steering/followup inter-process queue)
  │   └── events.tl (structured lifecycle events)
  ├── db.tl (SQLite conversation storage)
  ├── auth.tl (credential loading)
  ├── skills.tl (skill loading and expansion)
  ├── commands.tl (command loading and expansion)
  ├── sandbox.tl (sandbox supervisor: proxy lifecycle, child env)
  └── proxy.tl (HTTP CONNECT proxy for sandbox)

sys/tools/ (built-in tool definitions)
  ├── read.tl
  ├── write.tl
  ├── edit.tl
  └── bash.tl
```

## data flow

1. `bin/ah.tl` calls `init.main(arg)`.
2. `init.tl` parses CLI args, resolves session, loads tools and skills.
3. `tools.init_custom_tools(cwd)` loads tools from system → embed → project tiers.
   `--tool` CLI overrides are applied last (highest precedence).
4. system prompt = `sys/system.md` + tool guidance + `CLAUDE.md`/`AGENTS.md` + git context + skills list.
5. `loop.run_agent()` enters the agent loop:
   - builds API messages from conversation ancestry in `db.tl`.
   - calls `api.stream()` with system prompt, messages, tool definitions.
   - processes response: text output + tool calls.
   - executes tools via `tools.tl`, records results.
   - checks for compaction need (80% of context window).
   - checks for loop detection (3 identical turns → steering, 5 → break).
   - drains steering queue between iterations.
   - repeats until `end_turn`, error, interruption, or budget exceeded.

## build system

the build uses GNU make with cosmic (a lua runtime with batteries).

```
make ci              # canonical: tests + type checks
make test            # incremental test runner
make check-types     # teal type checker on all .tl files
make build           # compile .tl → .lua
make ah              # build self-contained executable
```

**compilation**: `%.tl` → `o/%.lua` via `cosmic --compile`.

**test runner**: each `test_*.tl` file is executed independently. results
are collected into `o/test-summary.txt` via `cosmic --report`.

**embedding**: the `ah` executable is built by:
1. compiling all `.tl` to `.lua` under `o/`.
2. staging into `o/embed/`: main.lua, library modules, system prompts,
   skills, tools, CI reference files. `sys/tools/*.tl` is compiled to
   `.lua` and placed at `o/embed/embed/sys/tools/`.
3. running `cosmic --embed o/embed --output o/bin/ah` to create a zip archive executable.

embedded files are accessible at runtime under `/zip/embed/`.

users can overlay additional files with `ah embed <dir>`. notably,
`env.d/` files (`KEY=VALUE` format) are loaded at startup to set
environment variables (e.g. API keys). see AGENTS.md for usage.

## cosmic dependency

ah depends on [cosmic](https://github.com/whilp/cosmic), a lua runtime.
the Makefile includes `deps/cosmic.mk` which pins URL and sha256 for both
cosmic and cosmic-debug. binaries depend on the `.mk` file — changing it
triggers re-fetch. cosmic provides: sqlite, http fetch, filesystem, process management,
signal handling, networking, json, sandbox primitives (unveil/pledge).

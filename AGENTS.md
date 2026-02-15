# AGENTS.md

agent-first documentation for working in this repository. read this before
making changes. everything here is optimized for agent legibility—it is the
system of record.

## what ah is

ah is a minimal agent harness. it manages the lifecycle of an LLM agent
session: prompt → API call → tool execution → loop. it provides session
persistence, conversation branching, sandboxed execution, context compaction,
and a PDCA work loop for autonomous issue resolution.

ah is written in [teal](https://github.com/teal-language/tl) (typed lua),
compiled to lua, and embedded into a single executable via
[cosmic](https://github.com/whilp/cosmic). the executable is a
self-contained zip archive containing lua modules, system prompts, skill
files, and CI reference files.

## repository layout

```
bin/ah.tl                  CLI entry point
lib/ah/init.tl             session management, prompt expansion, CLI commands
lib/ah/loop.tl             agent loop: API streaming, tool dispatch, loop detection
lib/ah/tools.tl            builtin tools (read, write, edit, bash) + custom tool loading
lib/ah/skills.tl           skill loading and /skill: expansion
lib/ah/api.tl              Claude Messages API client with streaming + retries
lib/ah/db.tl               SQLite conversation tree (messages, content blocks, events)
lib/ah/compact.tl          context window compaction (summarize when near limit)
lib/ah/truncate.tl         output truncation for API (full output preserved in DB)
lib/ah/queue.tl            inter-process coordination (steering, followup, locks)
lib/ah/events.tl           structured event system for lifecycle observability
lib/ah/commands.tl         slash-command expansion
lib/ah/auth.tl             credential loading (API key or OAuth)
lib/ah/proxy.tl            HTTP CONNECT proxy for sandboxed network access
lib/ah/work/init.tl        PDCA work orchestrator (plan → do → push → check → fix → act)
lib/ah/work/sandbox.tl     sandbox management: fork proxy, spawn child with unveil+pledge
lib/ah/work/issue.tl       GitHub issue fetching, selection, label management
lib/ah/work/action.tl      check verdict parsing and action execution (open PR, comment)
lib/ah/work/prompt.tl      prompt template reading and interpolation
lib/ah/work/util.tl        shared utilities (logging, file I/O, git env setup)
lib/ulid.tl                ULID generation and parsing
lib/build/reporter.tl      test/type-check result reporter
lib/build/make-help.tl     Makefile help generator
sys/system.md              default system prompt (embedded at /zip/embed/sys/system.md)
sys/claude.md              base CLAUDE.md (embedded, prepended to project CLAUDE.md)
sys/skills/*.md            built-in skills (plan, do, check, fix, pr, etc.)
sys/work/prompts/*.md      prompt templates for work phases
work.mk                    make-based PDCA work loop (alternative to `ah work`)
Makefile                   build system: compile, test, type-check, embed
.github/workflows/work.yml CI workflow: scheduled + manual work runs
.github/workflows/test.yml CI workflow: tests and type checks
```

## architecture

### the agent loop (`lib/ah/loop.tl`)

the core loop is `run_agent()`. it:

1. creates a user message in the conversation tree
2. builds API messages from ancestry (handles dangling tool_use repair)
3. streams a response from the Claude API
4. persists the assistant message atomically (transaction per message)
5. executes tool calls sequentially, persisting results atomically
6. detects repetitive tool call patterns (loop detection: warn at 3, break at 5)
7. checks for steering messages (injected by `--steer` from another process)
8. checks for followup messages (queued for after agent completes)
9. triggers context compaction when input tokens exceed 80% of context window
10. enforces token budgets (`--max-tokens`)
11. handles interruption (SIGINT) at any point with graceful cleanup

every message and content block is persisted to SQLite before the next
iteration. crashes at any point leave the database in a recoverable state.

### conversation tree (`lib/ah/db.tl`)

conversations are stored as a tree, not a linear list. each message has a
`parent_id`. branching happens via `@N` fork syntax—create a new branch from
any message in the history.

key tables:
- `messages`: id, parent_id, role, seq, tokens, stop_reason, model
- `content_blocks`: text, tool_use, tool_result (linked to message)
- `context`: key-value store (session name, state)
- `events`: structured event log (api_call_end, loop_detected, etc.)

### tools (`lib/ah/tools.tl`)

four builtin tools: `read`, `write`, `edit`, `bash`.

custom tools are loaded from three layers (later overrides earlier):
1. `/zip/embed/sys/tools/*.lua` (embedded system tools)
2. `~/.ah/tools/*.lua` (global user tools)
3. `.ah/tools/*.lua` (project tools)

CLI tools are loaded from `.ah/bin/` (executables become tools).

tool input is validated against JSON schema before execution. string-to-integer
coercion handles model quirks.

### skills (`lib/ah/skills.tl`)

skills are markdown files with yaml frontmatter (`name`, `description`).
they are listed in the system prompt so the agent can load them with `read`.
users invoke skills explicitly via `/skill:name`.

skills are loaded from:
1. `/zip/embed/sys/skills/` (built-in)
2. `/zip/embed/skills/` (user-embedded, overrides built-in by name)

### sandboxing (`lib/ah/proxy.tl`, `lib/ah/work/sandbox.tl`)

`--sandbox` mode provides defense in depth:
- **network**: fork an HTTP CONNECT proxy on a unix socket, route all traffic
  through it. the proxy has a destination allowlist (default: `api.anthropic.com:443`).
  child processes see `https_proxy` env var and have `inet` pledge revoked.
- **filesystem**: `unveil()` restricts visibility. workspace gets `rwxc`,
  protected directories (from earlier phases) get read-only.
- **syscalls**: `pledge()` drops capabilities to `stdio rpath wpath cpath flock
  tty proc exec execnative unix prot_exec`. blocked calls return `EPERM`
  instead of crashing.

### context compaction (`lib/ah/compact.tl`)

when input tokens exceed 80% of the model's context window, the loop sends
the current conversation to a separate API call with a summarization prompt
(no tools). the summary replaces api_messages for subsequent turns. the full
conversation is always preserved in the database—compaction is a view-layer
operation.

### the work loop (`lib/ah/work/init.tl`, `work.mk`)

the work loop implements PDCA (plan-do-check-act) for autonomous issue
resolution:

1. **plan**: fetch GitHub issues, select highest priority, spawn a sandboxed
   agent to produce `o/work/plan/plan.md`
2. **do**: spawn a sandboxed agent to execute the plan on a feature branch
   with incremental commits
3. **push**: push the feature branch to origin
4. **check**: spawn a sandboxed agent to review changes against the plan,
   produce a verdict (`pass`/`needs-fixes`/`fail`) and `actions.json`
5. **fix** (conditional): if verdict is `needs-fixes`, spawn a sandboxed
   agent to address check feedback, then push and re-check (up to 2 retries)
6. **act**: execute actions from the check verdict (open PR, comment on issue,
   update labels)

each phase runs as a separate `ah` subprocess with its own session database,
sandbox, and token budget. phases are isolated—earlier phase artifacts are
protected as read-only in later phases.

`work.mk` provides a make-based alternative with the same phase structure,
using make dependency tracking for convergence.

the CI workflow (`.github/workflows/work.yml`) runs the work loop on a
schedule (every 3 hours) or on manual dispatch.

## build system

```sh
make test          # run all tests (incremental)
make build         # compile all .tl → .lua
make ah            # build the executable archive
make check-types   # teal type checker
make ci            # test + check-types
make work          # run the PDCA work loop
make clean         # remove build artifacts
```

output goes to `o/`. the build is incremental—only changed files recompile.
tests run in isolated temp directories.

## language: teal

all source files are `.tl` (teal). teal is typed lua—it compiles to standard
lua. the type system is structural. key patterns in this codebase:

- `record` for struct types (Message, DB, Tool, Skill, etc.)
- `{string:any}` for untyped maps (API responses, JSON)
- `as` for type assertions when working with untyped data
- `global` for cross-module state (the `interrupted` flag)

compilation: `cosmic --compile file.tl > file.lua`
type checking: `cosmic --check-types file.tl`

set `TL_PATH` to resolve imports across `lib/` and `/zip/.lua/`.

## testing

tests are `lib/ah/test_*.tl` and `lib/ah/work/test_*.tl`. each test file is
a standalone script that exits 0 on success. tests use `assert()` for
validation.

run a single test: `make o/lib/ah/test_loop.tl.test.ok`

test results are written to `o/*.test.ok` with `pass:` or `fail:` prefix.
the reporter aggregates results.

## key conventions

- **atomic persistence**: every message write is wrapped in a SQLite
  transaction. the loop never has a partial message in the database.
- **crash recovery**: orphan messages (from interrupted transactions) are
  cleaned up on session resume. dangling tool_use blocks get synthetic
  error tool_results.
- **event-driven display**: the agent loop emits structured events
  (text_delta, tool_call_start, tool_call_end, api_call_end, etc.).
  display is handled by a callback—the CLI handler writes to stderr/stdout,
  but other handlers (JSON, web UI) can be substituted.
- **progressive disclosure**: system prompt lists skill names and descriptions.
  the agent loads full skill content with the `read` tool when needed.
- **prompt layering**: system prompt = embedded `sys/system.md` + embedded
  `sys/claude.md` + project `CLAUDE.md` + project `AGENTS.md` + runtime
  context (date, cwd, git branch/commit/remote) + skill list.
- **session isolation**: each session has its own `.ah/<ulid>.db` and
  `.ah/<ulid>.queue.db`. sessions can be listed, resumed, named, and forked.
- **inter-process coordination**: steering messages interrupt a running
  session. followup messages queue work for after the current turn completes.
  session locks prevent concurrent access (queued as followup instead).

## making changes

1. read the file before editing it. the `edit` tool requires exact string
   matches.
2. run `make test` after changes. fix failures before committing.
3. run `make check-types` to catch type errors.
4. keep files focused. the codebase is modular—each file has a clear
   responsibility.
5. when adding a new module, add tests in a corresponding `test_*.tl` file.
6. when modifying the agent loop or tools, consider crash recovery and
   atomic persistence.
7. commit messages should be descriptive. one logical change per commit.

## design principles

- **minimal**: ah does the least possible. no frameworks, no configuration
  languages, no plugin systems beyond the simple tool/skill loading.
- **legible**: the codebase is optimized for agent comprehension. short files,
  clear names, inline comments at decision points.
- **recoverable**: any interruption (SIGINT, crash, timeout, budget exceeded)
  leaves the system in a resumable state.
- **sandboxed**: untrusted code runs with restricted network, filesystem,
  and syscall access. defense in depth.
- **composable**: sessions, tools, skills, and commands layer independently.
  the work loop composes these primitives into autonomous workflows.
- **boring**: prefer well-understood patterns. teal is typed lua. sqlite is
  the database. make is the build system. each choice maximizes agent
  legibility and training-set coverage.

# ah

an agent harness — runs AI coding agents in your terminal.

## what ah is

ah manages the lifecycle of an LLM agent session: prompt, API call, tool
execution, loop. it works *with* your terminal, not instead of it.

the magic is in the models. ah gets out of the way.

- session persistence and conversation branching
- context compaction when the window fills up
- sandboxed execution so agents can't trash your system
- single portable binary — runs on linux, mac, windows, bsds

## key technology

ah is built on [cosmopolitan](https://github.com/jart/cosmopolitan)
(via [whilp/cosmopolitan](https://github.com/whilp/cosmopolitan)):

- **actually portable executables** — one binary, multiple platforms
- **openbsd-style unveil/pledge** — filesystem and syscall sandboxing for
  agent safety
- **comprehensive C stdlib** — available from lua, no external dependencies

the lua layer uses [cosmic](https://github.com/whilp/cosmic), an ergonomic
interface to cosmopolitan's lua runtime. all source is written in
[teal](https://github.com/teal-language/tl) (typed lua) — about 12.5k lines
across `lib/`, `sys/`, and `bin/`.

## quick start

```sh
make ah          # build the binary
./o/bin/ah       # run it
```

or build with debug symbols:

```sh
make ah-debug
```

run `./o/bin/ah --help` or `make help` for available commands.

## how it works

### tools

ah gives the agent 5 tools:

| tool | what it does |
|------|-------------|
| `read` | read files (text and images) |
| `write` | write files, creating directories as needed |
| `edit` | find-and-replace with uniqueness checking |
| `bash` | run commands with timeout and abort |
| `skill` | load specialized instruction sets |

### skills

skills are markdown prompts that give the agent focused instructions for
specific tasks. 7 are built in:

- `plan` — research a codebase, write a work plan
- `do` — execute a plan, make changes, commit
- `check` — review changes against the plan
- `fix` — address review feedback
- `init` — generate documentation for a repo
- `analyze-session` — find friction points in past sessions
- `write-skill` — author new skills with correct format and conventions

projects can define their own skills alongside the built-in ones.

### sandbox

`--sandbox` mode restricts agent execution:

- filesystem access limited via unveil
- syscalls restricted via pledge
- network routed through an HTTP CONNECT proxy

agents can work without being able to reach the internet or read files
outside the project.

### agent loop

the core loop is simple: send messages to the API, get a response, execute
any tool calls, repeat. ah handles streaming, token tracking, context
compaction, and conversation persistence in SQLite.

## development

```sh
make test          # run tests
make check-types   # teal type checking
make ci            # both, in parallel
make clean         # remove build artifacts
```

the project layout:

```
bin/ah.tl          CLI entry point
lib/ah/            core modules (~6k lines)
sys/tools/         built-in tool definitions
sys/skills/        built-in skill prompts
sys/system.md      default system prompt
docs/              detailed documentation
Makefile           build system
```

see `AGENTS.md` for full contributor documentation and conventions.


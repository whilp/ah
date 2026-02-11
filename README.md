# ah

ah is a minimal agent harness that runs Claude with tool access (read, write, edit, bash) in a sandboxed environment.

## Features

- **Tool Access**: Claude can read/write files, edit text, run shell commands
- **Conversation Trees**: branching conversations with git-like navigation
- **Work Loop**: autonomous PDCA (Plan-Do-Check-Act) cycle for task execution
- **Sandboxed Execution**: filesystem and network isolation with unveil/pledge
- **Session Management**: persistent SQLite storage with ULID-based sessions
- **Streaming**: real-time API response streaming
- **Skills**: reusable prompt templates

## Quickstart

Build:

```bash
make ah
```

Run:

```bash
o/bin/ah "write a hello world program in C"
```

Start work loop:

```bash
o/bin/ah work "add feature X"
```

## Documentation

- [Architecture](docs/architecture.md): system structure, data flow, sandbox model, work loop
- [Usage](docs/usage.md): building, running, commands, options, workflow

## Requirements

- tinylisp (tlc compiler)
- SQLite
- curl (for API requests)
- OpenBSD or cosmic.sandbox for sandboxing features

## Authentication

Requires Claude API access. ah discovers credentials from:

1. `ANTHROPIC_API_KEY` environment variable
2. `~/.anthropic/api_key` file
3. `~/.anthropic/oauth.json` file

## License

See LICENSE file.

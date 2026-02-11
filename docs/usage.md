# usage

## build

requires cosmic runtime (fetched automatically by makefile).

```bash
make build      # compile .tl to .lua
make test       # run tests
make ah         # build executable archive
make check-types # teal type checking
make ci         # test + type checks
```

## running

```bash
ah <prompt>           # send prompt to agent
ah                    # continue from last message
ah @N <prompt>        # fork from message N
```

### commands

| command | description |
|---------|-------------|
| `sessions` | list all sessions |
| `scan` | list messages in current branch |
| `tree` | show full conversation tree |
| `branches` | list branch tips |
| `diff @A @B` | compare branches |
| `checkout @N` | switch to message |
| `branch rm @N` | delete branch |
| `show [N]` | show message(s) |
| `rmm N...` | remove messages |
| `work [cmd]` | run work loop |
| `embed <dir>` | embed files into /zip/embed/ |
| `extract <dir>` | extract /zip/embed/ |

### options

| option | description |
|--------|-------------|
| `-n, --new` | start new session |
| `-S, --session ULID` | use specific session |
| `--db PATH` | custom database path |
| `-m, --model MODEL` | set model (sonnet, opus, haiku) |
| `--steer MSG` | send steering message |
| `--followup MSG` | queue followup message |
| `--max-tokens N` | token budget |

## sessions

sessions stored in `.ah/<ulid>.db`. each session is a sqlite database containing the conversation tree. queue messages stored in `.ah/<ulid>.queue.db`.

## work workflow

run autonomous tasks with the pdca work loop:

```bash
ah work plan    # research and write plan
ah work do      # execute plan
ah work push    # push branch
ah work check   # verify execution
ah work act     # create pr, comment
```

output written to `o/work/{plan,do,check,act}/`.

## configuration

### environment variables

| variable | description |
|----------|-------------|
| `ANTHROPIC_API_KEY` | api key for claude |
| `CLAUDE_CODE_OAUTH_TOKEN` | oauth token (alternative auth) |
| `AH_SANDBOX` | enable sandbox mode when set to 1 |

### system prompts

customize behavior by editing files in `sys/`:

- `sys/system.md` — base system prompt
- `sys/claude.md` — ah-specific context
- `sys/work/*.md` — work phase prompts

# ah

minimal agent harness for code. wraps claude api with tools, conversation trees, and sandboxed work loops.

## quickstart

```bash
# build
make ah

# set api key
export ANTHROPIC_API_KEY=sk-ant-...

# run
./o/bin/ah "write a function to parse csv"

# continue conversation
./o/bin/ah "add error handling"

# run work loop
./o/bin/ah work
```

## features

- **tools**: read, write, edit, bash with filesystem protection
- **conversation trees**: branch and fork from any message
- **work loop**: PDCA (plan-do-check-act) phases with sandbox isolation
- **session storage**: sqlite conversation history in `.ah/<ulid>.db`
- **single binary**: embeds all code and prompts, no runtime deps

## architecture

15 modules in `lib/ah/`:
- init.tl - CLI and session management
- loop.tl - agent loop with tool dispatch
- work.tl - PDCA work phases
- db.tl - conversation tree storage
- api.tl - claude streaming client
- tools.tl - four tools with unveil protection
- proxy.tl - network isolation for sandbox
- skills.tl, commands.tl, events.tl, queue.tl, auth.tl, compact.tl, truncate.tl

see [docs/architecture.md](docs/architecture.md) for details.

## usage

```bash
# basic
ah "prompt"                    # send message
ah @N "prompt"                 # fork from message N
ah -n "prompt"                 # new session

# navigation
ah scan                        # show current branch
ah tree                        # show full conversation tree
ah sessions                    # list all sessions

# work
ah work                        # run PDCA loop
export AH_PROTECT_DIRS=".git/*,.ah/*"
ah work:123 "add feature"      # work with protected dirs
```

see [docs/usage.md](docs/usage.md) for complete reference.

## building

requires cosmic (teal compiler) and luapak (lua bundler).

```bash
make ah        # build executable
make check     # type check
make clean     # remove artifacts
```

output: `o/bin/ah` - single executable with embedded lua + prompts.

## data

- sessions: `.ah/<ulid>.db` (sqlite)
- current session: `.ah/current` (symlink)
- work outputs: `o/work/<phase>/`

## sandbox

work phases run sandboxed:
- network restricted to api.anthropic.com via proxy
- filesystem protection via `AH_PROTECT_DIRS` globs
- prevents data exfiltration and destructive operations

disable with `-u` flag (use cautiously).

## license

see LICENSE file.

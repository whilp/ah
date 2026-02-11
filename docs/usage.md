# Usage

## Building

### Prerequisites

- make
- cosmic (teal compiler)
- luapak (lua bundler)

### Build Commands

```bash
# compile and build executable
make ah

# type check without building
make check

# clean build artifacts
make clean

# install to system (requires prefix set)
make install
```

Output binary: `o/bin/ah`

## Running

### Basic Usage

```bash
# start new conversation
ah "hello, write a function to parse JSON"

# continue current session
ah "now add error handling"

# force new session
ah -n "fresh start"
```

### Session Management

```bash
# list all sessions
ah sessions

# select specific session
ah -S <ulid> "message for this session"

# use custom database path
ah --db /path/to/session.db "message"
```

### Navigation

```bash
# show current branch messages
ah scan

# show full conversation tree
ah tree

# list all branch tips
ah branches

# fork from message N
ah @N "branch from here"
```

### Model Selection

```bash
# use specific claude model
ah -m claude-opus-4-20250514 "prompt"

# default model from init.tl
# claude-sonnet-4-20250514
```

### Options

- `-n` - start new session
- `-S <ulid>` - select session by ID
- `--db <path>` - use specific database file
- `-m <model>` - claude model name
- `-u` - unsandboxed mode (no proxy/unveil)
- `-d` - debug mode (verbose logging)

## Session Storage

### Location

Sessions stored in `.ah/<ulid>.db` sqlite files in current directory.

### Current Session

`.ah/current` symlink points to active session database. Auto-created on first run, updated when switching sessions with -S.

### Schema

Each session database contains:
- messages: conversation tree
- content_blocks: message content (text/tools)
- events: lifecycle events for debugging

Access with sqlite3:
```bash
sqlite3 .ah/<ulid>.db "SELECT seq, role FROM messages ORDER BY seq"
```

## Work Workflow

### Starting Work

```bash
# run PDCA loop on current state
ah work

# work with specific issue/ticket
ah work:123 "implement feature X"
```

### Work Process

1. **Plan** - agent researches and writes plan
   - output: `o/work/plan/plan.md`
   - can bail with `o/work/plan/update.md`

2. **Do** - agent executes plan on feature branch
   - creates branch: `work/<id>-<slug>`
   - output: `o/work/do/do.md`, `o/work/do/update.md`
   - commits changes

3. **Check** - agent reviews execution
   - output: `o/work/check/check.md`, `o/work/check/actions.json`
   - verdict: approve or revise

4. **Fix** - agent addresses issues (if needed)
   - runs if check verdict is "revise"
   - up to 2 attempts
   - output: `o/work/fix/fix.md`

5. **Act** - deterministic finalization
   - commits with message from plan
   - optionally pushes to remote

6. **Friction** - reflection on obstacles
   - output: `o/work/friction/friction.md`

### Work Outputs

All phase outputs in `o/work/<phase>/`:
- plan.md - detailed plan
- do.md - execution summary
- check.md - review verdict
- actions.json - remediation actions
- fix.md - fix attempts
- update.md - 2-4 line summary

### Branch Management

Work creates feature branch from current HEAD:
```bash
# after work completes
git log --oneline  # see new commits on feature branch

# merge if approved
git checkout main
git merge work/<id>-<slug>
```

Original branch unchanged. Work isolated to feature branch.

### Sandbox Protection

Work phases run sandboxed by default:
- network restricted to api.anthropic.com
- filesystem protection via AH_PROTECT_DIRS

Set protected paths:
```bash
export AH_PROTECT_DIRS=".git/*,.ah/*,vendor/*"
ah work
```

Disable sandbox (use cautiously):
```bash
ah -u work
```

## Tools

Agents have access to four tools:

**read** - examine files
```
read(path: str, offset?: int, limit?: int)
```

**write** - create or overwrite files
```
write(path: str, content: str)
```

**edit** - find and replace in files
```
edit(path: str, old_string: str, new_string: str)
```

**bash** - execute shell commands
```
bash(command: str, timeout?: int)
```

Tool outputs truncated to prevent context overflow (see truncate.tl for limits).

## Skills

Skills provide specialized instructions:

```bash
# list available skills
ls skills/

# agent loads with /skill:<name>
ah "/skill:debug analyze the crash"
```

Skills are markdown files with YAML frontmatter defining name, description, and content.

## Environment Variables

- `ANTHROPIC_API_KEY` - API key (required)
- `AH_PROTECT_DIRS` - protected path globs (comma-separated)
- `https_proxy` - proxy URL (auto-configured in sandbox)
- `AH_DEBUG` - enable debug logging

## Examples

### Simple conversation
```bash
ah "explain how the loop detection works"
ah "show me the code in loop.tl"
```

### Branching exploration
```bash
ah "what files are in lib/ah?"
ah @1 "actually, show me the database schema"  # fork from first message
ah scan  # see messages in current branch
```

### Work on feature
```bash
export AH_PROTECT_DIRS=".git/*,.ah/*"
ah work:42 "add rate limiting to api.tl"

# after completion
git log --oneline
git diff main..HEAD
```

### Session inspection
```bash
ah tree  # visualize conversation branches
ah sessions  # list all sessions
sqlite3 .ah/$(readlink .ah/current) ".tables"  # examine schema
```

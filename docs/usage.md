# Usage

## Building

Build the ah executable:

```bash
make ah
```

This produces `o/bin/ah`.

Run type checking:

```bash
make check-types
```

Run tests:

```bash
make test
```

## Running

### Basic Invocation

Start a new session:

```bash
ah "your prompt here"
```

Continue existing session:

```bash
ah "follow-up prompt"
```

Resume specific session:

```bash
ah --db .ah/<ulid>.db "prompt"
```

### Session Management

Sessions stored as `.ah/<ulid>.db` SQLite files. Each session maintains a conversation tree with branching support.

List all sessions:

```bash
ah sessions
```

Show session history:

```bash
ah scan
```

View conversation tree:

```bash
ah tree
```

## Commands

Commands start with `/` and expand to full prompts.

### Navigation Commands

**scan**: show message history with IDs

```bash
ah scan
```

**tree**: display conversation tree with branching

```bash
ah tree
```

**branches**: list available branches at current message

```bash
ah branches
```

**checkout**: switch to specific message in tree

```bash
ah checkout <message-id>
```

**show**: display message content

```bash
ah show <message-id>
```

**diff**: compare two messages

```bash
ah diff <id1> <id2>
```

### Work Command

**work**: execute PDCA work loop

```bash
ah work "issue description"
```

Runs plan → do → check → act phases with sandboxed execution.

## Options

### Session Options

**-n, --new**: force new session

```bash
ah -n "start fresh session"
```

**-S <name>**: named session (stored as .ah/session-<name>.db)

```bash
ah -S mywork "prompt"
```

**--db <path>**: specify database file

```bash
ah --db .ah/<ulid>.db "prompt"
```

### Model Options

**-m, --model**: select Claude model

```bash
ah -m opus "complex task"
ah -m haiku "simple task"
ah -m sonnet "balanced task"
```

Model aliases:
- sonnet: claude-sonnet-4-5-20250929 (default)
- opus: claude-opus-4-5-20251101
- haiku: claude-haiku-4-5-20251001

**--max-tokens**: set output token limit

```bash
ah --max-tokens 4096 "prompt"
```

### Steering Options

**--steer**: add steering prompt (prepended to user message)

```bash
ah --steer "be concise" "explain quantum computing"
```

**--followup**: add followup prompt (appended after assistant response)

```bash
ah --followup "now add tests" "write a parser function"
```

### Debug Options

**-v, --verbose**: increase verbosity

```bash
ah -v "prompt"
```

**--no-stream**: disable streaming output

```bash
ah --no-stream "prompt"
```

## Work Workflow

The work loop implements a PDCA (Plan-Do-Check-Act) cycle for autonomous task execution.

### Starting Work

```bash
ah work "add feature X to module Y"
```

or with named session:

```bash
ah -S feature-x work "implement feature X"
```

### Phases

1. **Plan**: Claude analyzes the issue and creates execution plan
   - Output: o/work/plan/plan.md
   - Contains: context, approach, target branch, commit message, validation

2. **Do**: Execute the plan in sandboxed environment
   - Creates feature branch
   - Makes changes
   - Runs validation
   - Commits changes
   - Output: o/work/do/do.md, o/work/do/update.md

3. **Check**: Verify the changes
   - Runs validation steps
   - Checks git status
   - Output: o/work/check/check.md

4. **Act**: Decide next step
   - Analyzes check results
   - Decides: done, friction, or fix
   - Output: o/work/act/act.md

### Sandbox Environment

During the do phase, execution runs in a sandbox with:

- **Filesystem restrictions**: read-only access to .ah/, lib/, sys/, bin/
- **Network isolation**: external access via HTTP proxy only
- **Protected output**: writes limited to o/work/ and /tmp

Activate sandbox:

```bash
AH_SANDBOX=1 ah work "task description"
```

### Work Output

All work artifacts written to `o/work/<phase>/`:

- o/work/plan/plan.md
- o/work/do/do.md
- o/work/do/update.md
- o/work/check/check.md
- o/work/act/act.md

### Iteration

If check phase fails, work loop enters fix cycle:
- Analyzes failure
- Creates fix plan
- Executes fix
- Rechecks

Continues until success or max iterations reached.

## Skills

Skills are reusable prompts stored in sys/skills/.

Invoke skill:

```bash
ah /skill:skillname
```

Skills can include frontmatter with metadata and provide specialized instructions for specific tasks.

## Environment Variables

**ANTHROPIC_API_KEY**: API key for Claude API

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

**AH_SANDBOX**: enable sandboxed execution

```bash
export AH_SANDBOX=1
```

**HTTP_PROXY/HTTPS_PROXY**: proxy for network access (set by work loop)

## Authentication

ah discovers authentication via:

1. ANTHROPIC_API_KEY environment variable
2. ~/.anthropic/api_key file
3. ~/.anthropic/oauth.json file (OAuth)

No configuration required if credentials exist in standard locations.

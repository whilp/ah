# architecture

ah is a minimal agent harness written in teal (typed lua).

## modules

| file | description |
|------|-------------|
| `bin/ah.tl` | cli entry point, calls `ah.main(arg)` |
| `lib/ah/init.tl` | cli interface, session management, prompt expansion, command parsing |
| `lib/ah/loop.tl` | agent loop: tool dispatch, event emission, compaction, loop detection |
| `lib/ah/db.tl` | sqlite storage for conversation tree (messages, content blocks, events) |
| `lib/ah/api.tl` | claude messages api with streaming, retry, oauth support |
| `lib/ah/tools.tl` | agent tools: read, write, edit, bash |
| `lib/ah/work.tl` | pdca work loop: plan/do/check/act phases with sandbox |
| `lib/ah/skills.tl` | skill loading from markdown with yaml frontmatter |
| `lib/ah/commands.tl` | command expansion for prompts starting with / |
| `lib/ah/auth.tl` | credential loading (ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN) |
| `lib/ah/queue.tl` | inter-process coordination: steering/followup messages |
| `lib/ah/proxy.tl` | http connect proxy for sandboxed network access |
| `lib/ah/compact.tl` | conversation compaction when context limit approached |
| `lib/ah/truncate.tl` | output truncation for api (full output in db) |
| `lib/ah/events.tl` | structured event types for lifecycle tracking |

## data flow

```
cli (init.tl)
  → loop (loop.tl)
    → api (api.tl) → claude messages api
    → tools (tools.tl) → read, write, edit, bash
  → db (db.tl) → sqlite
```

## storage model

sessions stored in `.ah/<ulid>.db` as sqlite databases. conversation stored as tree structure:

- **messages** — user/assistant turns with sequence numbers
- **content blocks** — text, tool_use, tool_result blocks within messages
- **events** — structured lifecycle events

queue stored separately in `.ah/<ulid>.queue.db` for inter-process coordination.

## sandbox

when `AH_SANDBOX=1`:

- `unveil()` restricts filesystem to cwd, /tmp, /usr, /bin, /lib, /etc/ssl
- `pledge()` limits syscalls: stdio, rpath, wpath, cpath, flock, tty, proc, exec, unix
- proxy provides network access only to api.anthropic.com

## pdca work loop

the work loop implements plan-do-check-act for autonomous tasks:

1. **plan** — research codebase, write plan.md (sandboxed agent)
2. **do** — execute plan, create commits (sandboxed agent)
3. **push** — push branch to remote (deterministic, unsandboxed)
4. **check** — verify execution against plan (sandboxed agent)
5. **fix** — address issues if needed-fixes verdict (up to 2 retries)
6. **act** — execute actions: comment_issue, create_pr (deterministic, unsandboxed)

output written to `o/work/{plan,do,check,act}/`.

## system prompts

- `sys/system.md` — base system prompt (terse coding assistant style)
- `sys/claude.md` — ah-specific context (tools, skills, guidelines)
- `sys/work/*.md` — work phase prompts (plan, do, check, fix, friction)
- `sys/work/prompts/` — issue prompt templates

# Architecture

ah is a minimal agent harness that runs Claude with tool access in a sandboxed environment.

## System Structure

### Core Modules

- **bin/ah.tl**: CLI entry point calling `ah.main()`
- **lib/ah/init.tl**: main CLI logic, session management, prompt loading, tool dispatch (1265 lines)
- **lib/ah/loop.tl**: agent loop with API streaming, tool execution, event emission, loop detection, compaction (751 lines)
- **lib/ah/db.tl**: SQLite conversation tree storage (messages, content_blocks, events, context) (672 lines)
- **lib/ah/api.tl**: Claude Messages API client with streaming, OAuth/API key auth, model aliases (440 lines)
- **lib/ah/tools.tl**: tool implementations (read, write, edit, bash) with binary detection, image support (774 lines)

### Extended Modules

- **lib/ah/commands.tl**: command expansion from `/` prefix (211 lines)
- **lib/ah/skills.tl**: skill loading with frontmatter parsing, invocation via `/skill:` (249 lines)
- **lib/ah/queue.tl**: steering/followup queue with session locking for concurrent access (347 lines)
- **lib/ah/compact.tl**: conversation summarization when approaching context limit (116 lines)
- **lib/ah/events.tl**: structured event system for lifecycle monitoring (251 lines)
- **lib/ah/auth.tl**: authentication discovery (API key, OAuth) (86 lines)
- **lib/ah/proxy.tl**: HTTP CONNECT proxy for sandboxed network access (198 lines)
- **lib/ah/truncate.tl**: output truncation for large tool results (123 lines)

### Work Loop Modules

- **lib/ah/work/init.tl**: work loop implementation with plan → do → check → act phases (879 lines)
- **lib/ah/work/util.tl**: work utilities
- **lib/ah/work/issue.tl**: issue management
- **lib/ah/work/action.tl**: action handling
- **lib/ah/work/prompt.tl**: prompt construction
- **lib/ah/work/sandbox.tl**: sandboxed execution

## Data Flow

```
User Input
    ↓
Prompt Loading (sys/*.md)
    ↓
Command Expansion (lib/ah/commands.tl)
    ↓
API Request (lib/ah/api.tl)
    ↓
Streaming Response (lib/ah/loop.tl)
    ↓
Tool Execution (lib/ah/tools.tl)
    ↓
Database Storage (lib/ah/db.tl)
    ↓
Event Emission (lib/ah/events.tl)
```

### Prompt System

System prompts from `sys/` directory:

- **sys/system.md**: base system prompt with terse style guide
- **sys/claude.md**: tool definitions and guidelines
- **sys/work/plan.md**: planning phase prompt
- **sys/work/do.md**: execution phase prompt
- **sys/work/check.md**: verification phase prompt
- **sys/work/analyze.md**: analysis phase prompt
- **sys/work/fix.md**: fix phase prompt
- **sys/work/friction.md**: friction detection prompt

### API Communication

Model aliases (from lib/ah/api.tl):
- sonnet → claude-sonnet-4-5-20250929
- opus → claude-opus-4-5-20251101
- haiku → claude-haiku-4-5-20251001

Authentication methods:
1. API key via ANTHROPIC_API_KEY or ~/.anthropic/api_key
2. OAuth via ~/.anthropic/oauth.json

## Conversation Tree

Session storage in `.ah/<ulid>.db` SQLite files.

### Schema

**messages table**:
- id (primary key)
- parent_id (references messages.id)
- seq (sibling sequence number)
- role (user/assistant)
- created_at

**content_blocks table**:
- id (primary key)
- message_id (foreign key)
- seq (block order)
- type (text/tool_use/tool_result/image)
- content (JSON)

**events table**:
- id (primary key)
- message_id (foreign key)
- type (event type)
- data (JSON)

**context table**:
- key (primary key)
- value (text)

### Branching

Messages form a tree via parent_id relationships. Each child has a seq number for sibling ordering. Commands like `checkout`, `branches`, `tree` navigate the conversation tree.

## Sandbox Model

Sandboxed execution activated with `AH_SANDBOX=1`.

### Filesystem Restrictions (unveil)

From lib/ah/work/sandbox.tl and lib/ah/init.tl:

Protected directories (read-only):
- .ah/ (session database)
- lib/ (ah source code)
- sys/ (system prompts)
- bin/ (executables)

Work directory:
- o/work/ (read-write, output location)

Temporary:
- /tmp (read-write)

### Syscall Restrictions (pledge)

Using cosmic.sandbox for OpenBSD-style pledge:
- stdio, rpath, wpath, cpath
- proc, exec (for bash tool)
- inet, dns (via proxy only)

### Network Isolation

Network access routed through HTTP CONNECT proxy (lib/ah/proxy.tl):
- Proxy spawned by work loop
- Environment variables set (HTTP_PROXY, HTTPS_PROXY)
- Allows controlled external access while maintaining isolation

## Work Loop

PDCA (Plan-Do-Check-Act) cycle implemented in lib/ah/work/init.tl.

### Phases

1. **Plan**: analyze issue, create execution plan
   - Input: issue description
   - Output: o/work/plan/plan.md with approach and validation
   - Prompt: sys/work/plan.md

2. **Do**: execute the plan
   - Input: plan.md
   - Output: o/work/do/do.md with changes and commit
   - Prompt: sys/work/do.md
   - Sandboxed execution with unveil/pledge

3. **Check**: verify changes
   - Input: do.md
   - Output: o/work/check/check.md with validation results
   - Prompt: sys/work/check.md

4. **Act**: analyze results, decide next step
   - Input: check.md
   - Output: o/work/act/act.md with decision (done/friction/fix)
   - Prompt: sys/work/analyze.md or sys/work/fix.md

### Workflow

```
Issue → Plan → Do → Check → Act
                ↑              ↓
                └── Fix ←──────┘
                     (if failed)
```

### Session Management

Work sessions stored in `.ah/work-<ulid>.db`. Each phase creates separate messages in the conversation tree. Sandboxed subprocess spawned for do phase with network proxy.

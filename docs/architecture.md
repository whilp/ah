# Architecture

## Overview

ah is an agent harness that wraps the Claude API with tools, conversation management, and a sandboxed work loop. The system is built in teal (typed lua) and compiles to a single self-contained executable.

## Modules

### Core Agent (`lib/ah/`)

**init.tl**  
CLI interface and session management. Parses command-line arguments, loads system and claude prompts from `sys/`, manages session storage in `.ah/<ulid>.db`. Implements commands for navigation (scan, tree, branches), session management, and prompt dispatch.

**loop.tl**  
Main agent loop. Sends messages to Claude API, dispatches tool calls, detects infinite loops, emits lifecycle events. Handles streaming responses and orchestrates tool execution through tools.tl.

**work.tl**  
PDCA (Plan-Do-Check-Act) work loop. Runs four phases in sequence: plan → do → check → act, with optional fix phase (up to 2 retries). Each phase runs in a sandboxed subprocess with proxy isolation. Stores phase outputs in `o/work/<phase>/`.

**db.tl**  
SQLite conversation storage. Implements message tree with parent_id links, sequential message numbering, branch navigation. Stores messages, content blocks (text/tool_use/tool_result), and structured events. Supports checkout to any message via @N syntax.

**api.tl**  
Claude Messages API client. Handles streaming requests with SSE parsing, automatic proxy detection from environment, request/response formatting. Supports model selection and system prompt injection.

**tools.tl**  
Four tool implementations: read (file content with offset/limit), write (create/overwrite), edit (find-replace), bash (shell execution with timeout). Enforces filesystem protection via unveil and AH_PROTECT_DIRS. Handles truncation for large outputs.

**skills.tl**  
Skill loading system. Parses markdown files with YAML frontmatter from skills directories. Skills provide specialized instructions loaded on-demand via `/skill:<name>` syntax.

**commands.tl**  
Command expansion from markdown. Loads command definitions with prompt templates, supports variable substitution.

**events.tl**  
Structured event system. Records agent lifecycle events (message_created, tool_called, loop_detected, etc.) with timestamps and metadata. Events stored in db, queryable for debugging and analysis.

**queue.tl**  
Inter-process message queue. Supports steering messages (interrupt current loop) and followup messages (append after completion). Used for coordination between work phases.

**proxy.tl**  
HTTP CONNECT proxy for sandbox network isolation. Allowlists api.anthropic.com:443, blocks all other destinations. Runs as subprocess with unix socket, configured via https_proxy environment variable.

**auth.tl**  
API key management. Loads ANTHROPIC_API_KEY from environment, validates format.

**compact.tl**  
Context window compaction. Summarizes old conversation history when approaching token limits. Preserves recent messages and regenerates conversation with summary.

**truncate.tl**  
Tool output truncation. Applies character and line limits to tool results before sending to API. Prevents context overflow from large command outputs.

## Data Flow

### Database Schema

Messages table:
- id (ulid primary key)
- parent_id (tree structure)
- seq (sequential number per branch)
- role (user/assistant)
- created_at, updated_at

Content blocks table:
- message_id (foreign key)
- index (order within message)
- type (text/tool_use/tool_result)
- content (json blob)

Events table:
- id (ulid primary key)
- created_at
- type (event name)
- data (json metadata)

### Message Tree

Conversations form a tree structure via parent_id links. Each message references its parent, enabling:
- branching: fork from any message with `ah @N prompt`
- navigation: checkout different branches with @N syntax
- history: traverse parent chain to root

The current message pointer tracks active branch tip. Commands default to operating on current branch but can target specific messages.

### Session Storage

Sessions stored in `.ah/<ulid>.db` sqlite files. Each session is independent with its own conversation tree. Session selection via -S flag or automatic current session detection from `.ah/current` symlink.

## Sandbox Model

### Proxy Isolation

Work phases run sandboxed subprocesses with network restrictions:

1. work.tl spawns `ah proxy <socket>` subprocess
2. Sets `https_proxy=unix://<socket>` for agent subprocess
3. Proxy allowlists only api.anthropic.com:443
4. All other network access blocked

Ensures agents can only reach Claude API, cannot exfiltrate data or fetch arbitrary URLs.

### Filesystem Protection

Tools enforce protection via two mechanisms:

**unveil** (OpenBSD-style filesystem visibility)  
Restricts which paths can be accessed. Default unveil allows cwd and temp dir.

**AH_PROTECT_DIRS** environment variable  
Comma-separated list of glob patterns to block. Write/edit/bash tools reject operations touching protected paths.

Example: `AH_PROTECT_DIRS=".git/*,.ah/*"` prevents modifying git state or session database.

### Sandbox vs Unsandboxed

Phases:
- **sandboxed**: plan, do, check, fix (agent generates code/changes)
- **unsandboxed**: act (deterministic commit), friction (reflection)

Sandboxed phases run with proxy + filesystem restrictions. Unsandboxed phases run with full system access for git operations.

## Work Loop

### PDCA Phases

Located in `sys/work/*.md`, loaded as system prompts for each phase:

**plan.md**  
Research and planning phase. Agent explores codebase, writes detailed plan to `o/work/plan/plan.md`. Can bail early by writing `o/work/plan/update.md` if work already complete.

**do.md**  
Execution phase. Agent follows plan, makes changes on feature branch. Writes `o/work/do/do.md` with change summary and commit SHA.

**check.md**  
Review phase. Agent examines do phase output, runs tests, writes verdict (approve/revise) to `o/work/check/check.md` and actions to `o/work/check/actions.json`.

**fix.md**  
Remediation phase (conditional). If check phase finds issues, agent addresses feedback. Up to 2 fix attempts, each followed by another check.

**act.md**  
Finalization phase. Deterministic commit with message from plan, push to remote if configured.

**friction.md**  
Reflection phase. Agent documents obstacles encountered, writes to `o/work/friction/friction.md`.

### Phase Coordination

1. work.tl creates new session for each phase
2. Loads phase prompt from `sys/work/<phase>.md`
3. Runs agent loop in subprocess (sandboxed or not)
4. Parses phase output files to determine next step
5. Transitions to next phase or exits

Phase outputs in `o/work/<phase>/` persist across phases, providing continuity.

### Branch Management

Work loop operates on feature branches:
- plan phase: create `work/<id>-<slug>` branch
- do phase: make changes on feature branch
- act phase: commit and optionally push

Original branch preserved, work isolated to feature branch.

## Build System

### Compilation

Makefile orchestrates build:

1. `cosmic build` compiles `.tl` → `.lua` (teal type checker + transpiler)
2. Lua files placed in `o/lib/ah/*.lua`
3. `bin/luapak` embeds lua code + `sys/` prompts into executable archive
4. Output: `o/bin/ah` single self-contained binary

No runtime dependencies beyond libc. All code and prompts bundled.

### Targets

- `make ah`: build executable
- `make check`: type check without codegen
- `make clean`: remove build artifacts
- `make install`: copy to system bin

### Archive Structure

The `ah` executable is a shell script prepended to tar archive:
- extracts to temp dir on first run
- executes embedded lua interpreter
- loads ah code from extracted files
- sys/ prompts available at runtime

See `bin/ah.tl` for CLI entry point.

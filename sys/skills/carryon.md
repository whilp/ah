---
name: carryon
description: Continue from a previous session. Reads the session DB directly — no API call. Injects a structured context summary and resumes work.
---

# carryon

Resume work from the previous session. reads the `.ah/*.db` session database
directly with `sqlite3` and formats a context block — no API summarization
call needed.

## Usage

```
/skill:carryon
```

invoke at the start of a new session to recover what was in progress. if you
know the session to continue from, pass the db path:

```
/skill:carryon .ah/01JMABCDEF.db
```

## Steps

### 1. Find the previous session DB

if no path was given, list all session databases and pick the most recent one
that is not the current session:

```bash
ls -t .ah/*.db 2>/dev/null | head -2 | tail -1
```

if only one db exists (current session), there is no previous session to
continue from. say so and stop.

assign the result to `SESSION` (e.g. `.ah/01JMABCDEF.db`).

### 2. Extract context from the DB

run these queries in order:

```bash
# session name (may be empty)
sqlite3 "$SESSION" "select value from context where key='session_name';" 2>/dev/null

# first user prompt
sqlite3 "$SESSION" "select content from content_blocks cb join messages m on cb.message_id=m.id where cb.block_type='text' and m.role='user' order by m.seq asc, cb.seq asc limit 1;" 2>/dev/null

# stop reason of last assistant turn
sqlite3 "$SESSION" "select stop_reason from messages where role='assistant' order by seq desc limit 1;" 2>/dev/null

# last 20 text exchanges (role + content), oldest first
sqlite3 "$SESSION" "select m.role, substr(cb.content,1,400) from messages m join content_blocks cb on cb.message_id=m.id where cb.block_type='text' order by m.seq desc, cb.seq desc limit 20;" 2>/dev/null | tac

# last 10 tool calls (name + truncated input)
sqlite3 "$SESSION" "select tool_name, substr(tool_input,1,200) from content_blocks where block_type='tool_use' order by rowid desc limit 10;" 2>/dev/null | tac
```

### 3. Format the context block

write a `## Previous Session Context` block in your response:

```
## Previous Session Context

**Session:** <name or db path>
**First prompt:** <first user message, truncated to 120 chars>
**Stop reason:** <end_turn | max_tokens | tool_use | ...>

### Recent exchanges
<last 20 text messages, formatted as "role: content">

### Recent tool calls
<last 10 tool_use blocks, formatted as "tool_name: input">

### Status
<one-sentence assessment: what was being worked on and where it left off>
```

### 4. Resume

state clearly what was in progress and what comes next. then continue the
work without waiting for confirmation, unless the stop reason was
`max_tokens` or the last message was incomplete (in which case ask the user
if they want to continue from that point).

## Rules

- do not call the API to summarize. read the DB directly.
- target the *previous* session, not the current one. the current session
  is the newest `.ah/*.db` file.
- limit text content to 400 chars per block and tool inputs to 200 chars.
  do not dump the full DB.
- if `sqlite3` is not available, say so and stop.
- if `.ah/` does not exist or has no `.db` files, say so and stop.
- do not modify the source session DB.

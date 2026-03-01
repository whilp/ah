---
name: carryon
description: Continue from a previous session by loading its compaction summary or recent history.
---

# carryon

Pick up where a previous session left off. reads the most recent `.ah/*.db` file,
extracts the compaction summary (if present), and uses it as starting context before
proceeding with the current task.

## Usage

```
/skill:carryon <what to continue or do next>
```

## Steps

### 1. Find the most recent session

```bash
ls -t .ah/*.db 2>/dev/null | head -1
```

if the command returns nothing, `.ah/` does not exist or has no sessions. skip to step 4.

### 2. Read the compaction summary

replace `<db>` with the path from step 1.

```bash
sqlite3 <db> "SELECT content FROM content_blocks WHERE block_type = 'text' AND content LIKE '[COMPACTION SUMMARY]%' ORDER BY rowid DESC LIMIT 1;"
```

if a row is returned, the text after the `[COMPACTION SUMMARY]` header is the summary.
use it directly as context for the current task. skip to step 4.

### 3. Reconstruct context from recent messages

if no compaction summary exists, read recent message content instead:

```bash
sqlite3 <db> "SELECT m.role, cb.content FROM messages m JOIN content_blocks cb ON cb.message_id = m.id WHERE cb.block_type = 'text' ORDER BY m.seq DESC LIMIT 20;"
```

use the retrieved messages to reconstruct what was happening.

### 4. Proceed with the task

report what context was found (summary, recent messages, or none), then
continue with the user's follow-up task without re-exploring everything from scratch.

## Rules

- if `.ah/` does not exist, note it and continue as a fresh start
- if the compaction summary seems incomplete (session interrupted mid-compaction), note this and fall back to recent messages
- do not modify any `.ah/*.db` files — read only
- prefer the most recent session's summary; ignore older sessions unless asked

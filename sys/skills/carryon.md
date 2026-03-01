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

if no compaction summary exists, use multiple signals to reconstruct what was happening.

**a. read the first messages** — understand how the session started and what the original goal was:

```bash
sqlite3 <db> "SELECT m.role, cb.content FROM messages m JOIN content_blocks cb ON cb.message_id = m.id WHERE cb.block_type = 'text' ORDER BY m.seq ASC LIMIT 5;"
```

**b. read recent messages** — understand where the session ended:

```bash
sqlite3 <db> "SELECT m.role, cb.content FROM messages m JOIN content_blocks cb ON cb.message_id = m.id WHERE cb.block_type = 'text' ORDER BY m.seq DESC LIMIT 20;"
```

**c. explore working state** — look for leftover artifacts from the previous session:

```bash
git log --oneline -5 2>/dev/null
git status 2>/dev/null
ls o/plan/ 2>/dev/null
ls o/do/ 2>/dev/null
```

use all retrieved signals together — session origin, recent messages, commits, and leftover artifacts — to reconstruct what was happening and what work remains.

### 4. Proceed with the task

report what context was found (compaction summary, reconstructed history, or none) and your understanding of:
- what was being worked on
- where it was left off
- what appears to remain

then **ask the user to confirm or clarify** before continuing:
- does the reconstruction match their intent?
- is there anything to correct or add?
- what do they want to do next (or confirm the follow-up task if one was provided)?

only proceed once the user confirms the understanding or provides clarification.

## Rules

- if `.ah/` does not exist, note it and continue as a fresh start
- if the compaction summary seems incomplete (session interrupted mid-compaction), note this and fall back to recent messages
- do not modify any `.ah/*.db` files — read only
- prefer the most recent session's summary; ignore older sessions unless asked

# session storage

source: `lib/ah/db.tl`

## database

each session is a SQLite database at `.ah/<ulid>.db`. the ULID encodes
the creation timestamp and sorts chronologically.

WAL mode is enabled for concurrent read access.

## schema

```sql
messages (
  id text primary key,          -- ULID
  parent_id text,               -- parent message ULID (NULL for root)
  role text not null,           -- "user" or "assistant"
  seq integer not null,         -- display sequence number
  created_at integer not null,  -- unix timestamp
  input_tokens integer,
  output_tokens integer,
  stop_reason text,
  model text,
  api_latency_ms integer
)

content_blocks (
  id text primary key,
  message_id text not null,
  block_type text not null,     -- "text", "tool_use", "tool_result"
  seq integer not null,
  content text,                 -- text content
  tool_id text,                 -- tool call ID
  tool_name text,
  tool_input text,              -- JSON
  tool_output text,             -- full output (not truncated)
  is_error integer default 0,
  duration_ms integer,
  details text                  -- JSON metadata
)

context (key text primary key, value text)  -- session metadata
events (id, message_id, event_type, created_at, details)
```

## conversation tree

messages form a tree via `parent_id`. this enables branching:

- **fork**: `ah @N <prompt>` creates a new user message with parent_id
  pointing to message N, starting a new branch.
- **ancestry**: `db.get_ancestry(id)` walks parent pointers to build the
  linear history for an API call.
- **leaves**: `db.get_leaf_messages()` returns branch tips (messages with
  no children).

commands: `scan` (list current branch), `tree` (full tree), `branches`
(list tips), `checkout @N` (switch), `branch rm @N` (delete), `diff @A @B`.

## session resolution

`init.tl` resolves which session to use:

1. `--db PATH`: use explicit database path.
2. `--name NAME`: find session by name in context table, or create new.
3. `-n`: force new session.
4. `-S PREFIX`: resolve by ULID prefix match.
5. default: use most recent session (highest ULID).

## queue

each session has a companion `.ah/<ulid>.queue.db` for inter-process
coordination.

- **session lock**: PID-based with 30s stale threshold and heartbeat.
  if a session is locked, new prompts are queued as followups.
- **steering**: `--steer MSG` injects messages into a running session
  (checked between loop iterations).
- **followup**: `--followup MSG` queues messages for after session completes.

## orphan cleanup

on startup, `db.cleanup_orphans()` removes messages with no content blocks
(artifacts of crashes during transaction).

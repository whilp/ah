# session storage

source: `lib/ah/db.tl`, `lib/ah/dbtypes.tl`, `lib/ah/dbquery.tl`,
`lib/ah/conversations.tl`, `lib/ah/queue.tl`

## database

each session is a single SQLite database at `.ah/ah.db`. conversations
within the session are rows in the `conversations` table.

WAL mode is enabled for concurrent read access. foreign keys are enforced
via `pragma foreign_keys=on`.

## schema

```
┌─────────────────────────┐
│      conversations      │
├─────────────────────────┤
│ id          text PK     │   ┌─────────────────────────┐
│ name        text        │   │      session_lock       │
│ created_at  integer NN  │   ├─────────────────────────┤
│ closed_at   integer     │   │ key          text PK    │
│ state       text NN     │   │ owner_pid    integer NN │
│             def 'idle'  │   │ started_at   integer NN │
└──────┬──────────────────┘   │ heartbeat_at integer NN │
       │                      └─────────────────────────┘
       │ 1
       │
       │ N                    ┌─────────────────────────┐
┌──────┴──────────────────┐   │        context          │
│        messages         │   ├─────────────────────────┤
├─────────────────────────┤   │ key   text PK           │
│ id              text PK │   │ value text NN           │
│ conversation_id text FK─┤   └─────────────────────────┘
│ parent_id       text FK─┼──►self (tree)
│ role            text NN │
│ seq             integer NN
│ created_at      integer NN
│ input_tokens    integer │
│ output_tokens   integer │
│ stop_reason     text    │
│ model           text    │
│ api_latency_ms  integer │
└──────┬──────────────────┘
       │ 1
       │
       │ N
┌──────┴──────────────────┐   ┌─────────────────────────┐
│    content_blocks       │   │        events           │
├─────────────────────────┤   ├─────────────────────────┤
│ id          text PK     │   │ id              text PK │
│ message_id  text FK NN  │   │ conversation_id text FK │
│ block_type  text NN     │   │ message_id      text FK │
│ seq         integer NN  │   │ event_type      text NN │
│ content     text        │   │ created_at      integer NN
│ tool_id     text        │   │ details         text    │
│ tool_name   text        │   └─────────────────────────┘
│ tool_input  text        │
│ tool_output text        │   ┌─────────────────────────┐
│ is_error    integer     │   │    queue_messages       │
│             def 0       │   ├─────────────────────────┤
│ duration_ms integer     │   │ id              text PK │
│ details     text        │   │ conversation_id text FK NN
└─────────────────────────┘   │ message_type    text NN │
                              │ content         text NN │
┌─────────────────────────┐   │ created_at      integer NN
│    work_iterations      │   │ consumed_at     integer │
├─────────────────────────┤   └─────────────────────────┘
│ id              text PK │
│ conversation_id text FK │
│ status          text NN │
│ metric_value    real    │
│ baseline_value  real    │
│ message         text    │
│ created_at      integer NN
└─────────────────────────┘
```

### foreign key cascades

- `messages.conversation_id` → `on delete cascade`
- `messages.parent_id` → `on delete set null`
- `content_blocks.message_id` → `on delete cascade`
- `events.conversation_id` → `on delete cascade`
- `events.message_id` → `on delete set null`
- `queue_messages.conversation_id` → `on delete cascade`
- `work_iterations.conversation_id` → `on delete set null`

## conversation history

messages form a tree via `parent_id`:

```
user[seq=0] ─── assistant[seq=1] ─── user[seq=2] ─── assistant[seq=3]
                      │
                      └── user[seq=2] (fork)
                              │
                              └── assistant[seq=3]
```

`db.get_ancestry(id)` walks parent pointers to build the linear history
for an API call.

## module structure

```
              CLI (init.tl)
                  │
    ┌─────────────┼─────────────┐
    ▼             ▼             ▼
conversations   queue       session_lock
 .create()     .add_steer()  .try_acquire()
 .resolve()    .add_followup()
    │             │             │
    └──────┬──────┘             │
           ▼                    │
     loop.tl (agent loop)      │
      │  │  │                  │
      │  │  └── events         │
      │  │    .log_event()     │
      │  │                     │
      │  └── messages          │
      │    .create_message()  .update_heartbeat()
      │    .add_content_block()
      │    .get_ancestry()
      │
      ▼
sessions.tl (display)
  .cmd_sessions_db()
  .cmd_usage()
```

types are defined in `dbtypes.tl` and shared by `db.tl` (core CRUD) and
`dbquery.tl` (read-heavy query helpers: events, token totals, orphan
cleanup, session state).

## session resolution

`init.tl` resolves which conversation to use:

1. `--db PATH`: use explicit database path.
2. `--name NAME`: find conversation by name, or create new.
3. `-n`: force new conversation.
4. `-S PREFIX`: resolve by ULID prefix match.
5. default: use most recent non-closed conversation.

## session state

conversation state (`idle`, `processing`, `closed`) is stored in the
`conversations.state` column. `db.get_session_state()` and
`db.set_session_state()` delegate to the current conversation.

## queue

each session has steering and followup queues via `queue_messages`:

- **session lock**: PID-based with 30s stale threshold and heartbeat.
  if a session is locked, new prompts are queued as followups.
- **steering**: `--steer MSG` injects messages into a running session
  (checked between loop iterations).
- **followup**: `--followup MSG` queues messages for after session completes.

## orphan cleanup

on startup, `db.cleanup_orphans()` removes leaf messages with no content
blocks (artifacts of crashes during transaction). the scan is limited to
the 100 most recent leaf messages.

## context table

the `context` table stores transient session cursors:

| key | value |
|-----|-------|
| `current_conversation` | ULID of active conversation |
| `current_message` | ULID of last message written |
| `session_name` | display name (legacy per-file sessions) |
| `work:benchmark` | path to benchmark script |
| `work:goal` | optimization goal text |

`set_context(key, nil)` deletes the row (avoids NOT NULL violations).

## transactions

all multi-write operations in `loop.tl` and `looptool.tl` are wrapped in
`begin_transaction`/`commit` with rollback on failure:

```lua
db.begin_transaction(d)
local msg = db.create_message(d, "user", parent_id)
db.add_content_block(d, msg.id, "text", {content = prompt})
if not db.commit(d) then db.rollback(d) end
```

a `with_transaction(db, fn)` helper is also available for simpler cases.

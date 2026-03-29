# session database audit

source: `lib/ah/db.tl`, `lib/ah/conversations.tl`, `lib/ah/queue.tl`, `lib/ah/work.tl`

## entity-relationship diagram

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
│ conversation_id text FK─┼───┘                         │
│ parent_id       text FK─┼──►self (tree)               │
│ role            text NN │                              │
│ seq             integer NN                             │
│ created_at      integer NN                             │
│ input_tokens    integer │                              │
│ output_tokens   integer │                              │
│ stop_reason     text    │                              │
│ model           text    │                              │
│ api_latency_ms  integer │                              │
└──────┬──────────────────┘                              │
       │ 1                                               │
       │                                                 │
       │ N                                               │
┌──────┴──────────────────┐   ┌─────────────────────────┐
│    content_blocks       │   │        events           │
├─────────────────────────┤   ├─────────────────────────┤
│ id          text PK     │   │ id              text PK │
│ message_id  text FK NN──┤   │ conversation_id text FK │
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
│ status          text NN │
│ metric_value    real    │
│ baseline_value  real    │
│ message         text    │
│ created_at      integer NN
└─────────────────────────┘
```

## data flow diagram

```
                   CLI (init.tl)
                       │
         ┌─────────────┼─────────────┐
         ▼             ▼             ▼
   conversations    queue       session_lock
    .create()      .add_steer()  .try_acquire()
    .resolve()     .add_followup()
         │             │             │
         └──────┬──────┘             │
                ▼                    │
          loop.tl (agent loop)      │
           │  │  │                  │
           │  │  └── events         │
           │  │    .log_event()     │
           │  │                     │
           │  └── messages ◄────────┘
           │    .create_message()  .update_heartbeat()
           │    .add_content_block()
           │    .get_ancestry()
           │
           ▼
     sessions.tl (display)
       .cmd_sessions_db()
       .cmd_usage()

                work.tl
                  │
     ┌────────────┼───────────┐
     ▼            ▼           ▼
  work_       context       conversations
  iterations  (benchmark,   .create()
  .record()   goal keys)
```

## message tree structure

```
messages form a tree via parent_id (not a flat list):

  user[seq=0] ─── assistant[seq=1] ─── user[seq=2] ─── assistant[seq=3]
                        │
                        └── user[seq=2] (fork)
                                │
                                └── assistant[seq=3]

get_ancestry(leaf) walks parent pointers → returns root-to-leaf path
```

## dual state tracking

```
                   ┌─────────────────┐
 context table:    │  session_state  │  values: idle | processing | closed
                   └────────┬────────┘
                            │  parallel
                   ┌────────┴────────┐
 conversations:    │  state column   │  values: idle | processing | closed
                   └─────────────────┘
```

---

## findings

### 1. dual state: `context.session_state` vs `conversations.state`

**severity: medium (correctness risk)**

Session state is tracked in two places:
- `context` table under key `session_state` (via `db.get_session_state`/`set_session_state`)
- `conversations.state` column (via `conversations.set_conversation_state`)

Both use the same values (`idle`, `processing`, `closed`) and are updated
at different points in `init.tl` and `loop.tl`. There is no guarantee they
stay in sync. If one is updated but not the other (e.g. crash between the
two writes), the system reads stale state.

**recommendation:** remove `session_state` from context. `conversations.state`
is the canonical source. `get_session_state`/`set_session_state` should
delegate to the current conversation's state column.

### 2. implicit conversation creation in `create_message`

**severity: medium (design smell)**

`create_message` (db.tl:268-280) creates a conversation implicitly if no
`conversation_id` is provided and none is in context. This "backward
compatibility" path duplicates the logic in `conversations.create_conversation`
but skips setting a name or clearing `current_message`. It's a hidden
side-effect that makes the conversation lifecycle harder to reason about.

**recommendation:** remove the implicit creation. All callers should pass
an explicit `conversation_id` or ensure one exists via
`conversations.create_conversation` first. This is already the case for
all production paths (init.tl always resolves/creates a conversation before
the loop runs).

### 3. `context` table used as a grab-bag

**severity: low (maintenance)**

The `context` table stores unrelated keys with no type safety:
- `current_conversation` (ULID)
- `current_message` (ULID)
- `session_state` (enum string)
- `session_name` (free text)
- `work:benchmark` (file path)
- `work:goal` (free text)

There's no schema for valid keys, no way to list what's stored, and
`set_context` accepts nil values (which inserts `NULL` into a `NOT NULL`
column — this will fail silently or throw depending on the SQLite binding).

**recommendation:** either (a) define a fixed enum of valid context keys
and validate in `set_context`, or (b) split into dedicated tables
(`work_config` for benchmark/goal, session metadata on `conversations`).
At minimum, guard against nil values in `set_context`.

### 4. `cleanup_orphans` is O(N) full table scan

**severity: low (performance)**

The orphan query joins all messages with all content_blocks and checks for
children. With large conversation histories this gets expensive. It runs
on every startup.

```sql
select m.id from messages m
  left join content_blocks c on c.message_id = m.id
  where not exists (select 1 from messages child where child.parent_id = m.id)
  group by m.id having count(c.id) = 0
```

**recommendation:** limit the scan to recent messages (e.g. last 100 by
`created_at`) since orphans are only created by crashes during the current
session. Or run cleanup only when the previous session ended abnormally
(check `session_state = 'processing'`).

### 5. no rollback on transaction failure in `loop.tl`

**severity: medium (correctness)**

All transaction blocks in `loop.tl` follow this pattern:
```lua
db.begin_transaction(d)
-- ... writes ...
db.commit(d)
```

None check the return value of `begin_transaction` or `commit`, and none
call `rollback` on failure. If `commit` fails (e.g. disk full, WAL
checkpoint failure), the transaction stays open, and subsequent operations
either silently join it or fail with "cannot start a transaction within a
transaction."

**recommendation:** wrap in pcall or check return values:
```lua
local ok = db.begin_transaction(d)
if not ok then return end
-- ... writes ...
ok = db.commit(d)
if not ok then db.rollback(d) end
```

Or use the `db._db:transaction(fn)` wrapper which handles this automatically.

### 6. `seq` computation is non-atomic

**severity: low (theoretical race)**

Both `create_message` and `add_content_block` compute `seq` by querying
the current max, then inserting with `max + 1`. This is a classic
read-then-write race. In practice it's safe because SQLite serializes
writers and all writes happen in the same process, but it's fragile if
the architecture ever changes (e.g. multiple workers sharing a db).

**recommendation:** use a single `INSERT ... SELECT` to compute seq
atomically:
```sql
insert into messages (..., seq, ...)
  select ..., coalesce(max(seq), -1) + 1, ...
  from messages where parent_id = ?
```

### 7. `delete_message` doesn't cascade to events

**severity: low (data consistency)**

`delete_message` deletes content_blocks and the message itself, but events
referencing that message_id remain as dangling references. The FK is
declared but SQLite doesn't enforce FKs by default (`PRAGMA
foreign_keys` is never enabled).

**recommendation:** either enable `PRAGMA foreign_keys = ON` with
`ON DELETE CASCADE`/`SET NULL` on the FK declarations, or add an explicit
delete of events in `delete_message`. Enabling `foreign_keys` is the
cleaner approach and catches other referential integrity issues.

### 8. foreign keys are declared but never enforced

**severity: medium (integrity)**

The schema declares `REFERENCES` constraints on multiple tables (messages
→ conversations, content_blocks → messages, events → conversations/messages,
queue_messages → conversations), but `PRAGMA foreign_keys` is never set.
SQLite ignores FK declarations unless this pragma is enabled. This means:
- Orphaned content_blocks can accumulate silently
- Events can reference deleted messages/conversations
- Queue messages can reference deleted conversations

**recommendation:** add `PRAGMA foreign_keys = ON` after opening the
database (before schema creation). Add `ON DELETE CASCADE` to
content_blocks.message_id and `ON DELETE SET NULL` to events.message_id.

### 9. `work_iterations` is conversation-orphaned

**severity: low (design)**

`work_iterations` has no FK to conversations. Work iterations span multiple
conversations (each `work run` creates a new conversation), but there's no
link back. You can't ask "which conversation produced this iteration."

**recommendation:** add a `conversation_id` FK to `work_iterations` to
enable tracing iterations back to their agent conversations.

### 10. `get_session_token_totals` uses `max(input_tokens)` globally

**severity: low (correctness)**

The query `max(input_tokens)` across all messages assumes the most recent
API call has the highest token count. This is approximately true (context
grows over time) but breaks after compaction, where the context window
shrinks. The `cmd_usage` function in `sessions.tl` uses a different
approach (parsing events), so there are two inconsistent methods for
computing the same metric.

**recommendation:** unify on the events-based approach. `api_call_end`
events already carry per-call token data. The `max(input_tokens)` query
on messages is an approximation that `cmd_usage` has already superseded.

### 11. `drain_queue` uses raw SQL transaction, not `db.begin_transaction`

**severity: low (consistency)**

`queue.tl:drain_queue` calls `self._db:exec("BEGIN IMMEDIATE")` and
`self._db:exec("COMMIT")` directly instead of using `db.begin_transaction`
and `db.commit`. This bypasses any future instrumentation or error handling
added to those wrappers.

**recommendation:** use `db.begin_transaction`/`db.commit`/`db.rollback`
for consistency. Or use `self._db:transaction(fn)`.

### 12. `set_context` with nil value violates NOT NULL

**severity: low (latent bug)**

`work.tl:cmd_reset` calls `db.set_context(d, "work:benchmark", nil)`.
The context table declares `value text not null`. Passing nil may insert
NULL depending on how the SQLite binding handles it, violating the
constraint. If the binding rejects it, the "reset" silently fails to
clear the key.

**recommendation:** change `set_context` to delete the row when value is
nil:
```lua
if value == nil then
  self._db:exec("delete from context where key = ?", key)
else
  self._db:exec("insert or replace into context (key, value) values (?, ?)", key, value)
end
```

---

## simplification opportunities

### A. merge `session_state` into conversations

Remove `get_session_state`/`set_session_state` from db.tl. Use
`conversations.get_conversation()`/`set_conversation_state()` as the
single source. This eliminates finding #1 and reduces the context table
by one key.

### B. remove implicit conversation creation from `create_message`

Lines 268-280 of db.tl can be deleted. All production code paths
(init.tl, work.tl) create conversations explicitly. This makes the
conversation lifecycle unambiguous.

### C. enable foreign keys + cascades

```sql
pragma foreign_keys = on;
```

Add to FK declarations:
```sql
content_blocks.message_id ... on delete cascade
events.message_id         ... on delete set null
events.conversation_id    ... on delete cascade
queue_messages.conversation_id ... on delete cascade
```

This replaces manual cascade logic in `delete_message` and prevents
dangling references globally.

### D. replace `context` grab-bag with typed storage

Move `work:benchmark` and `work:goal` to a `work_config` table (or
columns on a `work_state` singleton row). Move `session_name` to
`conversations.name`. Keep `context` only for `current_conversation`
and `current_message` cursors.

### E. fix `set_context(key, nil)` → delete

Small change, prevents NOT NULL violations:

```lua
if value == nil then
  self._db:exec("delete from context where key = ?", key)
  return
end
self._db:exec("insert or replace into context (key, value) values (?, ?)", key, value)
```

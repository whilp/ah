# single database design

status: proposal

## summary

replace per-session database files (`.ah/<ulid>.db`) with a single
`.ah/ah.db`. conversations are branches in one tree, not separate files.
"starting a new session" means creating a new root message.

## motivation

the current multi-file design exists to isolate sessions, but `ah` only
runs one session at a time. the isolation buys little and costs:

- **session resolution complexity**: `init.tl` has a 5-way priority chain
  (`--db`, `--name`, `-n`, `-S`, default) to figure out which file to open.
- **listing is O(n) file opens**: `list_sessions` opens every `.db` file
  to read metadata. slow with many sessions.
- **no cross-session queries**: can't search conversation history across
  sessions without opening every database.
- **file proliferation**: each session creates 3-5 files (db, wal, shm,
  queue.db, queue.db-wal).
- **queue is a separate db**: the queue needs its own file because the
  session db path must be known before opening, creating a chicken-and-egg
  for the lock.

## current architecture

```
.ah/
├── 01J5A...XY.db            ◄── session 1 (messages, content_blocks, context, events)
├── 01J5A...XY.db-wal
├── 01J5A...XY.db-shm
├── 01J5A...XY.queue.db      ◄── session 1 queue (queue_messages, session_lock)
├── 01J5A...XY.queue.db-wal
├── 01J8B...QR.db            ◄── session 2
├── 01J8B...QR.queue.db      ◄── session 2 queue
├── 01JCZ...MN.db            ◄── session 3
├── 01JCZ...MN.queue.db      ◄── session 3 queue
└── ...                         (3-5 files per session)
```

each session is isolated in its own sqlite file. listing sessions
requires opening every `.db` to read metadata:

```
list_sessions()
  ├─ opendir(".ah/")
  ├─ for each *.db matching ULID pattern:
  │   ├─ sqlite.open(file)           ◄── O(n) file opens
  │   ├─ get_message_count()
  │   ├─ get_first_user_prompt()
  │   ├─ get_context("session_name")
  │   └─ close()
  └─ sort by ULID descending
```

session resolution is a 5-way priority chain:

```
resolve session
  ├─ --db PATH?     ──► open file directly
  ├─ --name NAME?   ──► scan all files, match context key
  ├─ -n?            ──► ulid.generate() → new file
  ├─ -S PREFIX?     ──► scan all files, match ULID prefix
  └─ default        ──► sort files by name, take newest
```

## proposed architecture

```
.ah/
└── ah.db       ◄── single file: all conversations, queue, locks
```

one file. three WAL files max (db-wal, db-shm).

## design

### entity relationships

```
┌──────────────────────┐
│    conversations     │
│──────────────────────│
│ id          (PK)     │─────────┐
│ name                 │         │
│ created_at           │         │
│ closed_at            │         │
│ state                │         │
└──────────────────────┘         │
         │                       │
         │ 1:N                   │ 1:N
         ▼                       │
┌──────────────────────┐         │     ┌──────────────────────┐
│      messages        │         │     │   queue_messages      │
│──────────────────────│         │     │──────────────────────│
│ id          (PK)     │─────┐   │     │ id          (PK)     │
│ conversation_id (FK) │◄────┼───┘     │ conversation_id (FK) │
│ parent_id   (FK)     │◄──┐ │        │ message_type         │
│ role                 │   │ │        │ content              │
│ seq                  │   │ │        │ created_at           │
│ created_at           │   │ │        │ consumed_at          │
│ input_tokens         │   │ │        └──────────────────────┘
│ output_tokens        │   │ │
│ stop_reason          │   │ │
│ model                │   │ │
│ api_latency_ms       │   │ │
└──────────────────────┘   │ │
         │  ▲              │ │
         │  └──────────────┘ │    (parent_id self-reference
         │                   │     forms conversation tree)
         │ 1:N               │
         ▼                   │ 1:N
┌──────────────────────┐     │     ┌──────────────────────┐
│   content_blocks     │     │     │       events         │
│──────────────────────│     │     │──────────────────────│
│ id          (PK)     │     │     │ id          (PK)     │
│ message_id  (FK)     │     │     │ conversation_id (FK) │
│ block_type           │     │     │ message_id  (FK)     │
│ seq                  │     │     │ event_type           │
│ content              │     │     │ created_at           │
│ tool_id              │     │     │ details              │
│ tool_name            │     │     └──────────────────────┘
│ tool_input           │     │
│ tool_output          │     │
│ is_error             │     │     ┌──────────────────────┐
│ duration_ms          │     │     │    session_lock      │
│ details              │     │     │──────────────────────│
└──────────────────────┘     │     │ key         (PK)     │
                             │     │ owner_pid            │
┌──────────────────────┐     │     │ started_at           │
│      context         │     │     │ heartbeat_at         │
│──────────────────────│     │     └──────────────────────┘
│ key         (PK)     │     │
│ value                │     │          (global, not per-
└──────────────────────┘     │           conversation)
                             │
  (global kv: stores         │
   current_conversation)     │
```

### conversation tree (within one conversation)

```
conversation: 01J5A...XY

  msg-001 [user] "fix the login bug"
    │
    ├── msg-002 [assistant] "I'll look at auth.tl..."
    │     │
    │     ├── msg-003 [user] (tool_result: file content)
    │     │     │
    │     │     └── msg-004 [assistant] "Found the issue..."
    │     │           │
    │     │           └── msg-005 [user] "also fix logout"   ◄── current
    │     │
    │     └── msg-006 [user] (branch: different tool_result)
    │           │
    │           └── msg-007 [assistant] "alternative fix..."
    │
    └── msg-008 [assistant] (branch: retry from root)

  get_ancestry(msg-005) → [msg-001, msg-002, msg-003, msg-004, msg-005]
  get_ancestry(msg-007) → [msg-001, msg-002, msg-006, msg-007]
```

the tree structure is unchanged from current. `parent_id` links form
the chain. `conversation_id` on messages is only for indexing — ancestry
queries ignore it.

### multiple conversations in one db

```
ah.db
  │
  ├── conversation 01J5A...XY (state: closed)
  │     └── msg-001 → msg-002 → msg-003 → ... → msg-042
  │
  ├── conversation 01J8B...QR (state: closed)
  │     └── msg-043 → msg-044 → msg-045 → ... → msg-089
  │
  └── conversation 01JCZ...MN (state: idle)       ◄── current
        └── msg-090 → msg-091 → ... → msg-112

  context: { current_conversation: "01JCZ...MN" }
```

### session resolution (simplified)

```
resolve conversation
  ├─ --db PATH?     ──► open file directly (escape hatch, unchanged)
  ├─ --name NAME?   ──► SELECT id FROM conversations WHERE name = ?
  ├─ -n?            ──► INSERT INTO conversations
  ├─ -S PREFIX?     ──► SELECT id FROM conversations WHERE id LIKE ?||'%'
  └─ default        ──► SELECT id FROM conversations
                        WHERE state != 'closed'
                        ORDER BY id DESC LIMIT 1
```

### schema changes

add a `conversations` table. fold queue tables into the main db.

```sql
-- new: conversation roots
create table if not exists conversations (
  id text primary key,            -- ULID (replaces session ULID filenames)
  name text,                      -- optional human label (replaces context key)
  created_at integer not null,
  closed_at integer,              -- set when conversation ends
  state text not null default 'idle'  -- idle, processing, closed
);

-- existing, add conversation_id
create table if not exists messages (
  id text primary key,
  conversation_id text not null references conversations(id),
  parent_id text references messages(id),
  role text not null,
  seq integer not null,
  created_at integer not null,
  input_tokens integer,
  output_tokens integer,
  stop_reason text,
  model text,
  api_latency_ms integer
);

-- existing, unchanged
create table if not exists content_blocks (
  id text primary key,
  message_id text not null references messages(id),
  block_type text not null,
  seq integer not null,
  content text,
  tool_id text,
  tool_name text,
  tool_input text,
  tool_output text,
  is_error integer default 0,
  duration_ms integer,
  details text
);

-- existing, scope to conversation
create table if not exists events (
  id text primary key,
  conversation_id text references conversations(id),
  message_id text references messages(id),
  event_type text not null,
  created_at integer not null,
  details text
);

-- queue tables (folded in from queue.db)
create table if not exists queue_messages (
  id text primary key,
  conversation_id text not null references conversations(id),
  message_type text not null,
  content text not null,
  created_at integer not null,
  consumed_at integer
);

create table if not exists session_lock (
  key text primary key,
  owner_pid integer not null,
  started_at integer not null,
  heartbeat_at integer not null
);

-- replaces context table for conversation-scoped kv
-- global kv (current_conversation) lives in a simple context table
create table if not exists context (
  key text primary key,
  value text not null
);

create index if not exists idx_messages_conversation on messages(conversation_id);
create index if not exists idx_messages_parent on messages(parent_id);
create index if not exists idx_content_blocks_message on content_blocks(message_id);
create index if not exists idx_events_conversation on events(conversation_id);
create index if not exists idx_events_message on events(message_id);
create index if not exists idx_events_type on events(event_type);
create index if not exists idx_queue_conversation on queue_messages(conversation_id);
create index if not exists idx_queue_type on queue_messages(message_type);
create index if not exists idx_queue_consumed on queue_messages(consumed_at);
```

### what changes

| area | before | after |
|------|--------|-------|
| db path | `.ah/<ulid>.db` | `.ah/ah.db` |
| queue path | `.ah/<ulid>.queue.db` | same db |
| new session | `ulid.generate()` → new file | `insert into conversations` |
| session resolution | scan dir, open files, match | `select from conversations where ...` |
| session listing | `opendir` + open each db | `select from conversations join messages` |
| `--name` | scan all files for context key | `where name = ?` |
| `-S PREFIX` | scan all files for ULID prefix | `where id like ? || '%'` |
| default | sort files by name, take first | `order by id desc limit 1` |
| `-n` | generate ULID, create file | `insert into conversations` |
| `--db PATH` | use that file | still works (override) |
| cross-session search | impossible | `select from content_blocks join messages` |
| cleanup | `rm .ah/<ulid>.db*` | `delete from conversations where id = ?` cascade |
| `context` table | per-session kv | global kv (`current_conversation`, etc.) |

### queue folding

`queue.tl` currently manages its own sqlite connection. with one db:

- `queue_messages` gets a `conversation_id` column
- `session_lock` stays global (only one process runs at a time)
- `queue.open()` takes the main db handle instead of a separate path
- no more `.queue.db` files

### ancestry queries (unchanged)

`get_ancestry` works exactly as before. the recursive CTE walks
`parent_id` pointers, which are already scoped to a single conversation
by the tree structure. adding `conversation_id` to messages is for
indexing and listing, not for ancestry.

### migration

no migration. old per-session `.db` files are left in place and ignored.
the new code only opens `.ah/ah.db`. users who want old history can
read it with `sqlite3` directly, but there's no automatic import.

```
.ah/
├── ah.db                     ◄── new, all future conversations
├── 01J5A...XY.db             ◄── old, ignored
├── 01J5A...XY.queue.db       ◄── old, ignored
├── 01J8B...QR.db             ◄── old, ignored
└── ...
```

this keeps the change simple and avoids migration bugs. old files can
be cleaned up manually (`rm .ah/01*.db*`) whenever the user is ready.

### what gets deleted

- `sessions.tl`: `list_sessions` and `resolve_session` move to `db.tl`
  as simple queries. `cmd_sessions` and `cmd_usage` can stay.
- `queue.tl`: `open`/`close` collapse. lock and message functions take
  the main db handle.
- session resolution block in `init.tl` (~30 lines) → ~10 lines.
- filesystem scanning logic.

### risks

- **corruption blast radius**: one db means one point of failure. mitigated
  by WAL mode (crash-safe) and the fact that sqlite corruption from
  application bugs is rare. periodic `.ah/ah.db` backup is cheap.
- **db growth**: all history in one file. `VACUUM` is slow on large dbs.
  mitigated by the fact that conversation data is small (text + JSON).
  a year of heavy use might be 50-100MB.
- **concurrent access**: if two `ah` processes somehow run against the same
  `.ah/`, they'd contend on one WAL. the session lock already prevents
  this — it just moves from queue.db to the main db.

### what doesn't change

- message tree structure (parent_id chain)
- content_blocks schema
- compaction logic
- API message building
- tool dispatch
- `--db PATH` escape hatch

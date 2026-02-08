-- ah/db.lua: SQLite storage for conversation tree
local fs = require("cosmic.fs")
local sqlite = require("cosmic.sqlite")
local ulid = require("ulid")

local SCHEMA = [[
create table if not exists messages (
  id text primary key,
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

create table if not exists context (
  key text primary key,
  value text not null
);

create table if not exists events (
  id text primary key,
  message_id text references messages(id),
  event_type text not null,
  created_at integer not null,
  details text
);

create index if not exists idx_messages_parent on messages(parent_id);
create index if not exists idx_content_blocks_message on content_blocks(message_id);
create index if not exists idx_events_message on events(message_id);
create index if not exists idx_events_type on events(event_type);
]]

-- Type definitions
local record Statement
  bind: function(Statement, any...)
  exec: function(Statement)
  close: function(Statement)
end

local record Database
  exec: function(Database, string, any...): boolean, string
  exec_list: function(Database, string, {any}, integer): boolean, string
  prepare: function(Database, string): Statement, string
  query: function(Database, string, any...): function(): {string:any}
  transaction: function<T>(Database, function(): T): T
  close: function(Database)
end

local record DB
  _db: Database
end

local record Message
  id: string
  parent_id: string
  role: string
  seq: integer
  created_at: integer
  input_tokens: integer
  output_tokens: integer
  stop_reason: string
  model: string
  api_latency_ms: integer
end

local record ContentBlock
  id: string
  message_id: string
  block_type: string
  seq: integer
  content: string
  tool_id: string
  tool_name: string
  tool_input: string
  tool_output: string
  is_error: integer
  duration_ms: integer
  details: string
end

local record ContentBlockOpts
  content: string
  tool_id: string
  tool_name: string
  tool_input: string
  tool_output: string
  is_error: boolean
  duration_ms: integer
  details: string
end

local record UpdateOpts
  content: string
  tool_output: string
  is_error: boolean
end

local record MessageOpts
  input_tokens: integer
  output_tokens: integer
  stop_reason: string
  model: string
  api_latency_ms: integer
end

local record Event
  id: string
  message_id: string
  event_type: string
  created_at: integer
  details: string
end

local function get_db_path(): string
  local ah_dir = ".ah"
  fs.makedirs(ah_dir)
  return fs.join(ah_dir, "ah.db")
end

local function open(db_path?: string): DB, string
  db_path = db_path or get_db_path()

  -- Ensure parent directory exists for custom paths
  local parent = fs.dirname(db_path)
  if parent and parent ~= "" and parent ~= "." then
    fs.makedirs(parent)
  end

  local db, err = sqlite.open(db_path) as (Database, string)
  if not db then
    return nil, "failed to open database: " .. db_path .. ": " .. (err or "")
  end

  -- Enable WAL mode for better crash recovery and concurrent access
  local ok, pragma_err = db:exec("pragma journal_mode=wal")
  if not ok then
    db:close()
    return nil, "failed to enable WAL mode: " .. (pragma_err or "")
  end

  -- Set busy timeout to wait up to 5 seconds for locks
  ok, pragma_err = db:exec("pragma busy_timeout=5000")
  if not ok then
    db:close()
    return nil, "failed to set busy timeout: " .. (pragma_err or "")
  end

  -- Ensure writes are synced to disk (safety over speed)
  db:exec("pragma synchronous=normal")

  ok, pragma_err = db:exec(SCHEMA)
  if not ok then
    db:close()
    return nil, "failed to initialize schema: " .. (pragma_err or "")
  end

  return {_db = db} as DB, nil
end

local function close(self: DB)
  if self._db then
    self._db:close()
  end
end

-- Transaction support for atomic operations
local function begin_transaction(self: DB): boolean, string
  return self._db:exec("BEGIN IMMEDIATE")
end

local function commit(self: DB): boolean, string
  return self._db:exec("COMMIT")
end

local function rollback(self: DB): boolean, string
  return self._db:exec("ROLLBACK")
end

-- Context operations
local function get_context(self: DB, key: string): string
  for row in self._db:query("select value from context where key = ?", key) do
    return row.value as string
  end
  return nil
end

local function set_context(self: DB, key: string, value: string)
  self._db:exec("insert or replace into context (key, value) values (?, ?)", key, value)
end

-- Message operations
local function get_message(self: DB, id: string): Message
  for row in self._db:query("select * from messages where id = ?", id) do
    return row as Message
  end
  return nil
end

local function create_message(self: DB, role: string, parent_id?: string, opts?: MessageOpts): Message
  local id = ulid.generate()
  local now = os.time()
  opts = opts or {}

  local seq = 0
  if parent_id then
    for row in self._db:query("select seq from messages where id = ?", parent_id) do
      seq = (row.seq as integer) + 1
    end
  end

  local values: {any} = {id, parent_id, role, seq, now, opts.input_tokens, opts.output_tokens, opts.stop_reason, opts.model, opts.api_latency_ms}

  self._db:exec_list([[
    insert into messages (id, parent_id, role, seq, created_at, input_tokens, output_tokens, stop_reason, model, api_latency_ms)
    values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ]], values, 10)

  self._db:exec("insert or replace into context (key, value) values (?, ?)", "current_message", id)

  return {
    id = id,
    parent_id = parent_id,
    role = role,
    seq = seq,
    created_at = now,
    input_tokens = opts.input_tokens,
    output_tokens = opts.output_tokens,
    stop_reason = opts.stop_reason,
    model = opts.model,
    api_latency_ms = opts.api_latency_ms,
  }
end

local function get_current_message(self: DB): Message
  local id = get_context(self, "current_message")
  if id then
    return get_message(self, id)
  end
  return nil
end

local function set_current_message(self: DB, id: string)
  set_context(self, "current_message", id)
end

local function get_ancestry(self: DB, message_id: string): {Message}
  local messages: {Message} = {}

  -- Use recursive CTE to fetch entire ancestry chain in a single query
  for row in self._db:query([[
    with recursive ancestry(id, parent_id, role, seq, created_at,
      input_tokens, output_tokens, stop_reason, model, api_latency_ms, depth) as (
      select id, parent_id, role, seq, created_at,
        input_tokens, output_tokens, stop_reason, model, api_latency_ms, 0
      from messages where id = ?
      union all
      select m.id, m.parent_id, m.role, m.seq, m.created_at,
        m.input_tokens, m.output_tokens, m.stop_reason, m.model, m.api_latency_ms, a.depth + 1
      from messages m join ancestry a on m.id = a.parent_id
    )
    select id, parent_id, role, seq, created_at,
      input_tokens, output_tokens, stop_reason, model, api_latency_ms
    from ancestry order by depth desc
  ]], message_id) do
    table.insert(messages, row as Message)
  end

  return messages
end

local function get_last_message(self: DB): Message
  -- First try current_message from context
  local current = get_current_message(self)
  if current then
    return current
  end

  -- Otherwise find the most recent leaf (message with no children)
  for row in self._db:query([[
    select m.* from messages m
    where not exists (select 1 from messages c where c.parent_id = m.id)
    order by m.created_at desc limit 1
  ]]) do
    return row as Message
  end
  return nil
end

local function delete_message(self: DB, id: string)
  local current = get_context(self, "current_message")
  self._db:exec("delete from content_blocks where message_id = ?", id)
  self._db:exec("delete from messages where id = ?", id)

  if current == id then
    self._db:exec("delete from context where key = 'current_message'")
  end
end

-- Content block operations
local function add_content_block(self: DB, message_id: string, block_type: string, opts: ContentBlockOpts): ContentBlock
  opts = opts or {}
  local id = ulid.generate()

  local seq = 0
  for row in self._db:query("select max(seq) as max_seq from content_blocks where message_id = ?", message_id) do
    if row.max_seq then
      seq = (row.max_seq as integer) + 1
    end
  end

  local values: {any} = {
    id, message_id, block_type, seq,
    opts.content,
    opts.tool_id,
    opts.tool_name,
    opts.tool_input,
    opts.tool_output,
    opts.is_error and 1 or 0,
    opts.duration_ms,
    opts.details
  }

  self._db:exec_list([[
    insert into content_blocks (id, message_id, block_type, seq, content, tool_id, tool_name, tool_input, tool_output, is_error, duration_ms, details)
    values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ]], values, 12)

  return {
    id = id,
    message_id = message_id,
    block_type = block_type,
    seq = seq,
    content = opts.content,
    tool_id = opts.tool_id,
    tool_name = opts.tool_name,
    tool_input = opts.tool_input,
    tool_output = opts.tool_output,
    is_error = opts.is_error and 1 or 0,
    duration_ms = opts.duration_ms,
    details = opts.details,
  }
end

local function get_content_blocks(self: DB, message_id: string): {ContentBlock}
  local blocks: {ContentBlock} = {}
  for row in self._db:query([[
    select * from content_blocks where message_id = ?
    order by seq asc
  ]], message_id) do
    table.insert(blocks, row as ContentBlock)
  end
  return blocks
end

local function update_content_block(self: DB, id: string, opts: UpdateOpts)
  local sets: {string} = {}
  local values: {any} = {}

  if opts.content then
    table.insert(sets, "content = ?")
    table.insert(values, opts.content)
  end
  if opts.tool_output then
    table.insert(sets, "tool_output = ?")
    table.insert(values, opts.tool_output)
  end
  if opts.is_error ~= nil then
    table.insert(sets, "is_error = ?")
    table.insert(values, opts.is_error and 1 or 0)
  end

  if #sets == 0 then return end

  table.insert(values, id)
  local sql = "update content_blocks set " .. table.concat(sets, ", ") .. " where id = ?"
  self._db:exec_list(sql, values, #values)
end

-- Event logging
local function log_event(self: DB, event_type: string, message_id?: string, details?: string): Event
  local id = ulid.generate()
  local now = os.time()

  local values: {any} = {id, message_id, event_type, now, details}

  self._db:exec_list([[
    insert into events (id, message_id, event_type, created_at, details)
    values (?, ?, ?, ?, ?)
  ]], values, 5)

  return {
    id = id,
    message_id = message_id,
    event_type = event_type,
    created_at = now,
    details = details,
  }
end

local function get_events(self: DB, event_type?: string): {Event}
  local events: {Event} = {}
  local sql = "select * from events"
  if event_type then
    sql = sql .. " where event_type = ?"
  end
  sql = sql .. " order by created_at asc"

  if event_type then
    for row in self._db:query(sql, event_type) do
      table.insert(events, row as Event)
    end
  else
    for row in self._db:query(sql) do
      table.insert(events, row as Event)
    end
  end
  return events
end

local function get_message_by_seq(self: DB, seq: integer): Message
  for row in self._db:query([[
    select * from messages where seq = ?
    order by created_at asc limit 1
  ]], seq) do
    return row as Message
  end
  return nil
end

local function get_message_count(self: DB): integer
  for row in self._db:query("select count(*) as cnt from messages") do
    return (row.cnt or 0) as integer
  end
  return 0
end

-- Clean up orphan messages (messages without content blocks, from crashes)
-- Only deletes orphans that have no children (leaf orphans)
local function cleanup_orphans(self: DB): integer
  -- Find and delete leaf messages with no content blocks
  -- (messages that have no children pointing to them)
  local orphans: {string} = {}
  for row in self._db:query([[
    select m.id from messages m
    left join content_blocks c on c.message_id = m.id
    where not exists (select 1 from messages child where child.parent_id = m.id)
    group by m.id
    having count(c.id) = 0
  ]]) do
    table.insert(orphans, row.id as string)
  end

  for _, id in ipairs(orphans) do
    delete_message(self, id)
  end

  return #orphans
end

local function get_first_user_prompt(self: DB): string
  for row in self._db:query([[
    select content from content_blocks
    where block_type = 'text'
      and message_id in (
        select id from messages where role = 'user' order by seq asc limit 1
      )
    order by seq asc limit 1
  ]]) do
    return (row.content or "") as string
  end
  return ""
end

return {
  open = open,
  close = close,
  begin_transaction = begin_transaction,
  commit = commit,
  rollback = rollback,
  create_message = create_message,
  get_current_message = get_current_message,
  set_current_message = set_current_message,
  get_ancestry = get_ancestry,
  get_last_message = get_last_message,
  delete_message = delete_message,
  get_message_by_seq = get_message_by_seq,
  add_content_block = add_content_block,
  get_content_blocks = get_content_blocks,
  update_content_block = update_content_block,
  get_message_count = get_message_count,
  get_first_user_prompt = get_first_user_prompt,
  cleanup_orphans = cleanup_orphans,
  log_event = log_event,
  get_events = get_events,
  -- Export types for consumers
  DB = DB,
  Message = Message,
  ContentBlock = ContentBlock,
  ContentBlockOpts = ContentBlockOpts,
  MessageOpts = MessageOpts,
  Event = Event,
}

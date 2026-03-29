local fs = require("cosmic.fs")
local sqlite = require("cosmic.sqlite")
local ulid = require("ulid")
local ctime = require("cosmic.time")
local t = require("ah.dbtypes")

local SCHEMA = [[
create table if not exists conversations (
  id text primary key,
  name text,
  created_at integer not null,
  closed_at integer,
  state text not null default 'idle'
);

create table if not exists messages (
  id text primary key,
  conversation_id text not null references conversations(id) on delete cascade,
  parent_id text references messages(id) on delete set null,
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
  message_id text not null references messages(id) on delete cascade,
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
  conversation_id text references conversations(id) on delete cascade,
  message_id text references messages(id) on delete set null,
  event_type text not null,
  created_at integer not null,
  details text
);

create table if not exists queue_messages (
  id text primary key,
  conversation_id text not null references conversations(id) on delete cascade,
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

create table if not exists work_iterations (
  id text primary key,
  conversation_id text references conversations(id) on delete set null,
  status text not null,
  metric_value real,
  baseline_value real,
  message text,
  created_at integer not null
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
]]

-- Types imported from dbtypes.tl (shared with dbquery.tl)
local Database = t.Database
local DB = t.DB
local Conversation = t.Conversation
local ConversationOpts = t.ConversationOpts
local Message = t.Message
local ContentBlock = t.ContentBlock
local ContentBlockOpts = t.ContentBlockOpts
local UpdateOpts = t.UpdateOpts
local MessageOpts = t.MessageOpts
local Event = t.Event
local TokenTotals = t.TokenTotals

local function open(db_path?: string): DB, string
  if not db_path then
    local ah_dir = ".ah"
    fs.makedirs(ah_dir)
    db_path = fs.join(ah_dir, "ah.db")
  end

  local parent = fs.dirname(db_path)
  if parent and parent ~= "" and parent ~= "." then
    fs.makedirs(parent)
  end

  local db, err = sqlite.open(db_path) as(Database, string)
  if not db then
    return nil, "failed to open database: " .. db_path .. ": " .. (err or "")
  end

  local ok, pragma_err = db:exec("pragma journal_mode=wal")
  if not ok then db:close(); return nil, "failed to enable WAL mode: " .. (pragma_err or "") end
  ok, pragma_err = db:exec("pragma busy_timeout=5000")
  if not ok then db:close(); return nil, "failed to set busy timeout: " .. (pragma_err or "") end
  db:exec("pragma synchronous=normal")
  db:exec("pragma foreign_keys=on")
  ok, pragma_err = db:exec(SCHEMA)
  if not ok then db:close(); return nil, "failed to initialize schema: " .. (pragma_err or "") end

  return {_db = db} as DB, nil
end

local function close(self: DB)
  if self._db then self._db:close() end
end

local function begin_transaction(self: DB): boolean, string
  return self._db:exec("BEGIN IMMEDIATE")
end

local function commit(self: DB): boolean, string
  return self._db:exec("COMMIT")
end

local function rollback(self: DB): boolean, string
  return self._db:exec("ROLLBACK")
end

local function with_transaction(self: DB, fn: function())
  local ok, _ = begin_transaction(self)
  if not ok then return end
  local success = pcall(fn)
  if success then
    ok, _ = commit(self)
    if not ok then rollback(self) end
  else
    rollback(self)
  end
end

local function get_context(self: DB, key: string): string
  for row in self._db:query("select value from context where key = ?", key) do
    return row.value as string
  end
  return nil
end

local function set_context(self: DB, key: string, value: string)
  if value == nil then
    self._db:exec("delete from context where key = ?", key)
  else
    self._db:exec("insert or replace into context (key, value) values (?, ?)", key, value)
  end
end

local function get_message(self: DB, id: string): Message
  for row in self._db:query("select * from messages where id = ?", id) do
    return row as Message
  end
  return nil
end

local function create_message(self: DB, role: string, parent_id?: string, opts?: MessageOpts, conversation_id?: string): Message
  local id = ulid.generate()
  local now = math.floor((ctime.now())) as integer
  opts = opts or {}

  local seq = 0
  if parent_id then
    for row in self._db:query("select seq from messages where id = ?", parent_id) do
      seq = (row.seq as integer) + 1
    end
  end

  -- If no conversation_id provided, use the current conversation from context
  if not conversation_id then
    conversation_id = get_context(self, "current_conversation")
  end

  self._db:exec_list([[
    insert into messages (id, conversation_id, parent_id, role, seq, created_at, input_tokens, output_tokens, stop_reason, model, api_latency_ms)
    values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ]], {id, conversation_id, parent_id, role, seq, now, opts.input_tokens, opts.output_tokens, opts.stop_reason, opts.model, opts.api_latency_ms}, 11)

  self._db:exec("insert or replace into context (key, value) values (?, ?)", "current_message", id)

  return {
    id = id, parent_id = parent_id, role = role, seq = seq, created_at = now,
    input_tokens = opts.input_tokens, output_tokens = opts.output_tokens,
    stop_reason = opts.stop_reason, model = opts.model, api_latency_ms = opts.api_latency_ms,
  }
end

local function get_current_message(self: DB): Message
  local id = get_context(self, "current_message")
  if id then return get_message(self, id) end
  return nil
end

local function get_ancestry(self: DB, message_id: string): {Message}
  local messages: {Message} = {}
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
  local current = get_current_message(self)
  if current then return current end
  local cid = get_context(self, "current_conversation")
  if cid then
    for row in self._db:query([[select m.* from messages m
      where m.conversation_id = ? and not exists (select 1 from messages c where c.parent_id = m.id)
      order by m.created_at desc limit 1]], cid) do
      return row as Message
    end
  end
  return nil
end

local function delete_message(self: DB, id: string)
  local current = get_context(self, "current_message")
  self._db:exec("delete from content_blocks where message_id = ?", id)
  self._db:exec("delete from events where message_id = ?", id)
  self._db:exec("delete from messages where id = ?", id)
  if current == id then
    self._db:exec("delete from context where key = 'current_message'")
  end
end

local function add_content_block(self: DB, message_id: string, block_type: string, opts: ContentBlockOpts): ContentBlock
  opts = opts or {}
  local id = ulid.generate()

  -- Atomic seq computation via INSERT...SELECT to avoid read-then-write race
  self._db:exec_list([[
    insert into content_blocks (id, message_id, block_type, seq, content, tool_id, tool_name, tool_input, tool_output, is_error, duration_ms, details)
    select ?, ?, ?, coalesce(max(seq), -1) + 1, ?, ?, ?, ?, ?, ?, ?, ?
    from content_blocks where message_id = ?
  ]], {id, message_id, block_type, opts.content, opts.tool_id, opts.tool_name, opts.tool_input, opts.tool_output, opts.is_error and 1 or 0, opts.duration_ms, opts.details, message_id}, 12)

  local seq = 0
  for row in self._db:query("select seq from content_blocks where id = ?", id) do
    seq = row.seq as integer
  end

  return {
    id = id, message_id = message_id, block_type = block_type, seq = seq,
    content = opts.content, tool_id = opts.tool_id, tool_name = opts.tool_name,
    tool_input = opts.tool_input, tool_output = opts.tool_output,
    is_error = opts.is_error and 1 or 0, duration_ms = opts.duration_ms, details = opts.details,
  }
end

local function get_content_blocks(self: DB, message_id: string): {ContentBlock}
  local blocks: {ContentBlock} = {}
  for row in self._db:query("select * from content_blocks where message_id = ? order by seq asc", message_id) do
    table.insert(blocks, row as ContentBlock)
  end
  return blocks
end

local function update_content_block(self: DB, id: string, opts: UpdateOpts)
  local sets: {string} = {}
  local values: {any} = {}
  if opts.content then table.insert(sets, "content = ?"); table.insert(values, opts.content) end
  if opts.tool_output then table.insert(sets, "tool_output = ?"); table.insert(values, opts.tool_output) end
  if opts.is_error ~= nil then table.insert(sets, "is_error = ?"); table.insert(values, opts.is_error and 1 or 0) end
  if #sets == 0 then return end
  table.insert(values, id)
  self._db:exec_list("update content_blocks set " .. table.concat(sets, ", ") .. " where id = ?", values, #values)
end

-- Query helpers live in dbquery.tl to keep this file under the line limit.
-- Inject callbacks to avoid circular require, then re-export.
local dbquery = require("ah.dbquery")
dbquery.set_callbacks(get_context, delete_message)

local log_event = dbquery.log_event
local get_events = dbquery.get_events
local get_message_count = dbquery.get_message_count
local cleanup_orphans = dbquery.cleanup_orphans
local get_session_token_totals = dbquery.get_session_token_totals
local get_session_state = dbquery.get_session_state
local set_session_state = dbquery.set_session_state
local get_first_user_prompt = dbquery.get_first_user_prompt

return {
  open = open, close = close,
  begin_transaction = begin_transaction, commit = commit, rollback = rollback, with_transaction = with_transaction,
  get_message = get_message, create_message = create_message,
  get_ancestry = get_ancestry, get_last_message = get_last_message,
  add_content_block = add_content_block, get_content_blocks = get_content_blocks,
  update_content_block = update_content_block,
  delete_message = delete_message,
  get_message_count = get_message_count, get_first_user_prompt = get_first_user_prompt,
  cleanup_orphans = cleanup_orphans,
  log_event = log_event, get_events = get_events,
  get_context = get_context, set_context = set_context,
  get_session_state = get_session_state, set_session_state = set_session_state,
  get_session_token_totals = get_session_token_totals,
  -- Types
  DB = DB, TokenTotals = TokenTotals, Message = Message,
  ContentBlock = ContentBlock, ContentBlockOpts = ContentBlockOpts,
  MessageOpts = MessageOpts, Event = Event,
  Conversation = Conversation, ConversationOpts = ConversationOpts,
}

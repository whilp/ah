-- ah/db.lua: SQLite storage for sessions and messages
local fs = require("cosmic.fs")
local sqlite = require("cosmic.sqlite")
local ulid = require("ulid")

local SCHEMA = [[
create table if not exists sessions (
  id text primary key,
  name text unique,
  created_at integer not null,
  updated_at integer not null,
  cwd text,
  system_prompt text,
  model text
);

create table if not exists messages (
  id text primary key,
  session_id text not null references sessions(id),
  parent_id text references messages(id),
  role text not null,
  seq integer not null,
  created_at integer not null
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
  is_error integer default 0
);

create table if not exists context (
  key text primary key,
  value text not null
);

create index if not exists idx_messages_session on messages(session_id);
create index if not exists idx_messages_parent on messages(parent_id);
create index if not exists idx_content_blocks_message on content_blocks(message_id);
]]

-- Type definitions
local record Statement
  bind: function(Statement, any...)
  exec: function(Statement)
  close: function(Statement)
end

local record Database
  exec: function(Database, string, any...): boolean, string
  prepare: function(Database, string): Statement, string
  query: function(Database, string, any...): function(): {string:any}
  close: function(Database)
end

local record DB
  _db: Database
end

local record Session
  id: string
  name: string
  created_at: integer
  updated_at: integer
  cwd: string
  system_prompt: string
  model: string
  message_count: integer
end

local record Message
  id: string
  session_id: string
  parent_id: string
  role: string
  seq: integer
  created_at: integer
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
end

local record ContentBlockOpts
  content: string
  tool_id: string
  tool_name: string
  tool_input: string
  tool_output: string
  is_error: boolean
end

local record UpdateOpts
  content: string
  tool_output: string
  is_error: boolean
end

local function get_db_path(): string
  local home = os.getenv("HOME") or ""
  local ah_dir = fs.join(home, ".ah")
  fs.makedirs(ah_dir)
  return fs.join(ah_dir, "ah.db")
end

local function open(db_path?: string): DB, string
  db_path = db_path or get_db_path()
  local db, err = sqlite.open(db_path) as (Database, string)
  if not db then
    return nil, "failed to open database: " .. db_path .. ": " .. (err or "")
  end

  local ok, schema_err = db:exec(SCHEMA)
  if not ok then
    db:close()
    return nil, "failed to initialize schema: " .. (schema_err or "")
  end

  return {_db = db} as DB, nil
end

local function close(self: DB)
  if self._db then
    self._db:close()
  end
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

-- Session operations
local function create_session(self: DB, name?: string, cwd?: string, system_prompt?: string, model?: string): Session
  local id = ulid.generate()
  local now = os.time()

  -- Use explicit non-nil values to avoid Lua vararg nil-dropping issue
  local stmt = self._db:prepare([[
    insert into sessions (id, name, created_at, updated_at, cwd, system_prompt, model)
    values (?, ?, ?, ?, ?, ?, ?)
  ]])
  if stmt then
    stmt:bind(id, name or "", now, now, cwd or "", system_prompt or "", model or "")
    stmt:exec()
    stmt:close()
  end

  set_context(self, "current_session", id)

  return {
    id = id,
    name = name,
    created_at = now,
    updated_at = now,
    cwd = cwd,
    system_prompt = system_prompt,
    model = model,
  }
end

local function get_session(self: DB, id: string): Session
  for row in self._db:query("select * from sessions where id = ?", id) do
    return row as Session
  end
  return nil
end

local function get_session_by_name(self: DB, name: string): Session
  -- First try exact name match
  for row in self._db:query("select * from sessions where name = ?", name) do
    return row as Session
  end

  -- Then try ID prefix match
  for row in self._db:query("select * from sessions where id like ? || '%'", name) do
    return row as Session
  end
  return nil
end

local function list_sessions(self: DB): {Session}
  local sessions: {Session} = {}
  local sql = [[
    select s.*,
      (select count(*) from messages m where m.session_id = s.id) as message_count
    from sessions s
    order by s.updated_at desc
  ]]
  for row in self._db:query(sql) do
    table.insert(sessions, row as Session)
  end
  return sessions
end

local function delete_session(self: DB, id: string)
  self._db:exec([[
    delete from content_blocks where message_id in
    (select id from messages where session_id = ?)
  ]], id)

  self._db:exec("delete from messages where session_id = ?", id)
  self._db:exec("delete from sessions where id = ?", id)

  local current = get_context(self, "current_session")
  if current == id then
    self._db:exec("delete from context where key = 'current_session'")
  end
end

local function get_current_session(self: DB): Session
  local id = get_context(self, "current_session")
  if id then
    return get_session(self, id)
  end
  return nil
end

local function set_current_session(self: DB, id: string)
  set_context(self, "current_session", id)
end

-- Message operations
local function get_message(self: DB, id: string): Message
  for row in self._db:query("select * from messages where id = ?", id) do
    return row as Message
  end
  return nil
end

local function create_message(self: DB, session_id: string, role: string, parent_id?: string): Message
  local id = ulid.generate()
  local now = os.time()

  local seq = 0
  if parent_id then
    for row in self._db:query("select seq from messages where id = ?", parent_id) do
      seq = (row.seq as integer) + 1
    end
  end

  self._db:exec([[
    insert into messages (id, session_id, parent_id, role, seq, created_at)
    values (?, ?, ?, ?, ?, ?)
  ]], id, session_id, parent_id, role, seq, now)

  self._db:exec("update sessions set updated_at = ? where id = ?", now, session_id)

  set_context(self, "current_message", id)

  return {
    id = id,
    session_id = session_id,
    parent_id = parent_id,
    role = role,
    seq = seq,
    created_at = now,
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
  local current_id = message_id

  while current_id do
    local msg = get_message(self, current_id)
    if not msg then break end
    table.insert(messages, 1, msg)
    current_id = msg.parent_id
  end

  return messages
end

local function get_last_message(self: DB, session_id: string): Message
  local current = get_current_message(self)
  if current and current.session_id == session_id then
    return current
  end

  for row in self._db:query([[
    select * from messages where session_id = ?
    order by seq desc, created_at desc limit 1
  ]], session_id) do
    return row as Message
  end
  return nil
end

local function delete_message(self: DB, id: string)
  self._db:exec("delete from content_blocks where message_id = ?", id)
  self._db:exec("delete from messages where id = ?", id)

  local current = get_context(self, "current_message")
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

  self._db:exec([[
    insert into content_blocks (id, message_id, block_type, seq, content, tool_id, tool_name, tool_input, tool_output, is_error)
    values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ]],
    id, message_id, block_type, seq,
    opts.content,
    opts.tool_id,
    opts.tool_name,
    opts.tool_input,
    opts.tool_output,
    opts.is_error and 1 or 0
  )

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
  local stmt = self._db:prepare(sql)
  if stmt then
    stmt:bind(table.unpack(values))
    stmt:exec()
    stmt:close()
  end
end

local function get_message_by_seq(self: DB, session_id: string, seq: integer): Message
  for row in self._db:query([[
    select * from messages where session_id = ? and seq = ?
    order by created_at asc limit 1
  ]], session_id, seq) do
    return row as Message
  end
  return nil
end

return {
  open = open,
  close = close,
  create_session = create_session,
  get_session = get_session,
  get_session_by_name = get_session_by_name,
  list_sessions = list_sessions,
  delete_session = delete_session,
  get_current_session = get_current_session,
  set_current_session = set_current_session,
  create_message = create_message,
  get_current_message = get_current_message,
  get_ancestry = get_ancestry,
  get_last_message = get_last_message,
  delete_message = delete_message,
  get_message_by_seq = get_message_by_seq,
  add_content_block = add_content_block,
  get_content_blocks = get_content_blocks,
  update_content_block = update_content_block,
  -- Export types for consumers
  DB = DB,
  Session = Session,
  Message = Message,
  ContentBlock = ContentBlock,
  ContentBlockOpts = ContentBlockOpts,
}

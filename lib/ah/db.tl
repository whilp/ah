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

local function get_db_path()
  local home = os.getenv("HOME") or ""
  local ah_dir = fs.join(home, ".ah")
  fs.makedirs(ah_dir)
  return fs.join(ah_dir, "ah.db")
end

local function open(db_path)
  db_path = db_path or get_db_path()
  local db, err = sqlite.open(db_path)
  if not db then
    return nil, "failed to open database: " .. db_path .. ": " .. (err or "")
  end

  local ok, schema_err = db:exec(SCHEMA)
  if not ok then
    db:close()
    return nil, "failed to initialize schema: " .. (schema_err or "")
  end

  return {_db = db}
end

local function close(self)
  if self._db then
    self._db:close()
  end
end

-- Context operations
local function get_context(self, key)
  for row in self._db:query("select value from context where key = ?", key) do
    return row.value
  end
  return nil
end

local function set_context(self, key, value)
  self._db:exec("insert or replace into context (key, value) values (?, ?)", key, value)
end

-- Session operations
local function create_session(self, name, cwd, system_prompt, model)
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

local function get_session(self, id)
  for row in self._db:query("select * from sessions where id = ?", id) do
    return row
  end
  return nil
end

local function get_session_by_name(self, name)
  -- First try exact name match
  for row in self._db:query("select * from sessions where name = ?", name) do
    return row
  end

  -- Then try ID prefix match
  for row in self._db:query("select * from sessions where id like ? || '%'", name) do
    return row
  end
  return nil
end

local function list_sessions(self)
  local sessions = {}
  local sql = [[
    select s.*,
      (select count(*) from messages m where m.session_id = s.id) as message_count
    from sessions s
    order by s.updated_at desc
  ]]
  for row in self._db:query(sql) do
    table.insert(sessions, row)
  end
  return sessions
end

local function delete_session(self, id)
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

local function get_current_session(self)
  local id = get_context(self, "current_session")
  if id then
    return get_session(self, id)
  end
  return nil
end

local function set_current_session(self, id)
  set_context(self, "current_session", id)
end

-- Message operations
local function get_message(self, id)
  for row in self._db:query("select * from messages where id = ?", id) do
    return row
  end
  return nil
end

local function create_message(self, session_id, role, parent_id)
  local id = ulid.generate()
  local now = os.time()

  local seq = 0
  if parent_id then
    for row in self._db:query("select seq from messages where id = ?", parent_id) do
      seq = row.seq + 1
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

local function get_current_message(self)
  local id = get_context(self, "current_message")
  if id then
    return get_message(self, id)
  end
  return nil
end

local function set_current_message(self, id)
  set_context(self, "current_message", id)
end

local function get_ancestry(self, message_id)
  local messages = {}
  local current_id = message_id

  while current_id do
    local msg = get_message(self, current_id)
    if not msg then break end
    table.insert(messages, 1, msg)
    current_id = msg.parent_id
  end

  return messages
end

local function get_last_message(self, session_id)
  local current = get_current_message(self)
  if current and current.session_id == session_id then
    return current
  end

  for row in self._db:query([[
    select * from messages where session_id = ?
    order by seq desc, created_at desc limit 1
  ]], session_id) do
    return row
  end
  return nil
end

local function delete_message(self, id)
  self._db:exec("delete from content_blocks where message_id = ?", id)
  self._db:exec("delete from messages where id = ?", id)

  local current = get_context(self, "current_message")
  if current == id then
    self._db:exec("delete from context where key = 'current_message'")
  end
end

-- Content block operations
local function add_content_block(self, message_id, block_type, opts)
  opts = opts or {}
  local id = ulid.generate()

  local seq = 0
  for row in self._db:query("select max(seq) as max_seq from content_blocks where message_id = ?", message_id) do
    if row.max_seq then
      seq = row.max_seq + 1
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

local function get_content_blocks(self, message_id)
  local blocks = {}
  for row in self._db:query([[
    select * from content_blocks where message_id = ?
    order by seq asc
  ]], message_id) do
    table.insert(blocks, row)
  end
  return blocks
end

local function update_content_block(self, id, opts)
  local sets = {}
  local values = {}

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
  local stmt, err = self._db:prepare(sql)
  if stmt then
    stmt:bind(table.unpack(values))
    stmt:exec()
    stmt:close()
  end
end

local function get_message_by_seq(self, session_id, seq)
  for row in self._db:query([[
    select * from messages where session_id = ? and seq = ?
    order by created_at asc limit 1
  ]], session_id, seq) do
    return row
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
}

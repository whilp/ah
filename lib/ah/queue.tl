-- ah/queue.tl: steering and followup queue for inter-process coordination
local sqlite = require("cosmic.sqlite")
local ulid = require("ulid")
local proc = require("cosmic.proc")
local signal = require("cosmic.signal")

local SCHEMA = [[
create table if not exists queue_messages (
  id text primary key,
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

create index if not exists idx_queue_type on queue_messages(message_type);
create index if not exists idx_queue_consumed on queue_messages(consumed_at);
]]

-- Stale lock threshold in seconds
local STALE_THRESHOLD = 30

local record Statement
  bind: function(Statement, any ...)
  exec: function(Statement)
  close: function(Statement)
end

local record Database
  exec: function(Database, string, any ...): boolean, string
  exec_list: function(Database, string, {any}, integer): boolean, string
  prepare: function(Database, string): Statement, string
  query: function(Database, string, any ...): function(): {string: any}
  close: function(Database)
end

local record QueueDB
  _db: Database
  _path: string
end

local record QueueMessage
  id: string
  message_type: string
  content: string
  created_at: integer
  consumed_at: integer
end

local record LockInfo
  owner_pid: integer
  started_at: integer
  heartbeat_at: integer
end

local function open(db_path: string): QueueDB, string
  local db, err = sqlite.open(db_path) as(Database, string)
  if not db then
    return nil, "failed to open queue database: " .. db_path .. ": " .. (err or "")
  end

  -- Enable WAL mode for better concurrent access
  local ok, pragma_err = db:exec("pragma journal_mode=wal")
  if not ok then
    db:close()
    return nil, "failed to enable WAL mode: " .. (pragma_err or "")
  end

  -- Set busy timeout to wait for locks
  ok, pragma_err = db:exec("pragma busy_timeout=5000")
  if not ok then
    db:close()
    return nil, "failed to set busy timeout: " .. (pragma_err or "")
  end

  db:exec("pragma synchronous=normal")

  ok, pragma_err = db:exec(SCHEMA)
  if not ok then
    db:close()
    return nil, "failed to initialize queue schema: " .. (pragma_err or "")
  end

  return {_db = db, _path = db_path} as QueueDB, nil
end

local function close(self: QueueDB)
  if self._db then
    self._db:close()
  end
end

-- Get current lock info if any
local function get_lock_info(self: QueueDB): LockInfo
  for row in self._db:query("select owner_pid, started_at, heartbeat_at from session_lock where key = 'lock'") do
    return {
      owner_pid = row.owner_pid as integer,
      started_at = row.started_at as integer,
      heartbeat_at = row.heartbeat_at as integer,
    }
  end
  return nil
end

-- Check if session is currently locked by another process
local function is_locked(self: QueueDB): boolean, integer
  local info = get_lock_info(self)
  if not info then
    return false, nil
  end

  local now = os.time()
  local age = now - info.heartbeat_at

  -- Check if lock is stale
  if age > STALE_THRESHOLD then
    return false, info.owner_pid
  end

  -- Check if owner process is still alive
  local my_pid = proc.getpid()
  if info.owner_pid == my_pid then
    return false, nil -- We own it
  end

  -- Try to check if the process exists via kill(pid, 0)
  local process_exists = signal.kill(info.owner_pid, 0)
  if not process_exists then
    -- Process doesn't exist, lock is stale
    return false, info.owner_pid
  end

  return true, info.owner_pid
end

-- Try to acquire the session lock
-- Returns: true if acquired, false if already held by another process
local function try_acquire_lock(self: QueueDB): boolean, string
  local now = os.time()
  local my_pid = proc.getpid()

  local info = get_lock_info(self)

  if info then
    -- Check if it's our own lock
    if info.owner_pid == my_pid then
      -- Update heartbeat and continue
      self._db:exec("update session_lock set heartbeat_at = ? where key = 'lock'", now)
      return true, nil
    end

    -- Check if lock is stale
    local age = now - info.heartbeat_at
    local process_dead = not signal.kill(info.owner_pid, 0)

    if age > STALE_THRESHOLD or process_dead then
      -- Claim stale lock
      local ok, err = self._db:exec(
        "update session_lock set owner_pid = ?, started_at = ?, heartbeat_at = ? where key = 'lock'",
        my_pid, now, now)
      if not ok then
        return false, "failed to claim stale lock: " .. (err or "")
      end
      return true, nil
    end

    -- Lock held by active process
    return false, "session locked by pid " .. info.owner_pid
  end

  -- No existing lock, create one
  local ok, err = self._db:exec(
    "insert into session_lock (key, owner_pid, started_at, heartbeat_at) values ('lock', ?, ?, ?)",
    my_pid, now, now)
  if not ok then
    return false, "failed to create lock: " .. (err or "")
  end

  return true, nil
end

-- Release the session lock
local function release_lock(self: QueueDB): boolean
  local my_pid = proc.getpid()
  local info = get_lock_info(self)

  if info and info.owner_pid == my_pid then
    self._db:exec("delete from session_lock where key = 'lock'")
    return true
  end

  return false
end

-- Update heartbeat timestamp (call before each API call)
local function update_heartbeat(self: QueueDB): boolean
  local now = os.time()
  local my_pid = proc.getpid()

  local ok = self._db:exec(
    "update session_lock set heartbeat_at = ? where key = 'lock' and owner_pid = ?",
    now, my_pid)

  return ok
end

-- Add a steering message to the queue
local function add_steer(self: QueueDB, content: string): QueueMessage
  local id = ulid.generate()
  local now = os.time()

  self._db:exec_list(
    "insert into queue_messages (id, message_type, content, created_at) values (?, ?, ?, ?)",
    {id, "steer", content, now}, 4)

  return {
    id = id,
    message_type = "steer",
    content = content,
    created_at = now,
  }
end

-- Add a followup message to the queue
local function add_followup(self: QueueDB, content: string): QueueMessage
  local id = ulid.generate()
  local now = os.time()

  self._db:exec_list(
    "insert into queue_messages (id, message_type, content, created_at) values (?, ?, ?, ?)",
    {id, "followup", content, now}, 4)

  return {
    id = id,
    message_type = "followup",
    content = content,
    created_at = now,
  }
end

-- Drain all unconsumed steering messages (returns them in order, marks as consumed)
local function drain_steering(self: QueueDB): {QueueMessage}
  local messages: {QueueMessage} = {}
  local now = os.time()

  local ok = self._db:exec("BEGIN IMMEDIATE")
  if not ok then
    return messages
  end

  -- Collect unconsumed steering messages (ordered by rowid for insertion order)
  for row in self._db:query([[
    select id, message_type, content, created_at from queue_messages
    where message_type = 'steer' and consumed_at is null
    order by rowid asc
  ]]) do
    table.insert(messages, {
        id = row.id as string,
        message_type = row.message_type as string,
        content = row.content as string,
        created_at = row.created_at as integer,
      })
  end

  -- Mark them as consumed
  if #messages > 0 then
    self._db:exec(
      "update queue_messages set consumed_at = ? where message_type = 'steer' and consumed_at is null",
      now)
  end

  self._db:exec("COMMIT")
  return messages
end

-- Drain all unconsumed followup messages (returns them in order, marks as consumed)
local function drain_followup(self: QueueDB): {QueueMessage}
  local messages: {QueueMessage} = {}
  local now = os.time()

  local ok = self._db:exec("BEGIN IMMEDIATE")
  if not ok then
    return messages
  end

  -- Collect unconsumed followup messages (ordered by rowid for insertion order)
  for row in self._db:query([[
    select id, message_type, content, created_at from queue_messages
    where message_type = 'followup' and consumed_at is null
    order by rowid asc
  ]]) do
    table.insert(messages, {
        id = row.id as string,
        message_type = row.message_type as string,
        content = row.content as string,
        created_at = row.created_at as integer,
      })
  end

  -- Mark them as consumed
  if #messages > 0 then
    self._db:exec(
      "update queue_messages set consumed_at = ? where message_type = 'followup' and consumed_at is null",
      now)
  end

  self._db:exec("COMMIT")
  return messages
end

-- Get count of pending messages by type
local function pending_count(self: QueueDB, message_type?: string): integer
  local sql = "select count(*) as cnt from queue_messages where consumed_at is null"
  if message_type then
    sql = sql .. " and message_type = ?"
    for row in self._db:query(sql, message_type) do
      return (row.cnt or 0) as integer
    end
  else
    for row in self._db:query(sql) do
      return (row.cnt or 0) as integer
    end
  end
  return 0
end

return {
  -- Database operations
  open = open,
  close = close,

  -- Lock operations
  try_acquire_lock = try_acquire_lock,
  release_lock = release_lock,
  update_heartbeat = update_heartbeat,
  is_locked = is_locked,
  get_lock_info = get_lock_info,

  -- Queue operations
  add_steer = add_steer,
  add_followup = add_followup,
  drain_steering = drain_steering,
  drain_followup = drain_followup,
  pending_count = pending_count,

  -- Types
  QueueDB = QueueDB,
  QueueMessage = QueueMessage,
  LockInfo = LockInfo,

  -- Constants
  STALE_THRESHOLD = STALE_THRESHOLD,
}

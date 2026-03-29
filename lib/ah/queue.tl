-- ah/queue.tl: steering, followup queue and session lock on db.DB
local db = require("ah.db")
local ulid = require("ulid")
local proc = require("cosmic.proc")
local signal = require("cosmic.signal")
local ctime = require("cosmic.time")

local STALE_THRESHOLD = 30

local record QueueMessage
  id: string
  conversation_id: string
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

-- Lock management (global, not per-conversation)

local function get_lock_info(self: db.DB): LockInfo
  for row in self._db:query("select owner_pid, started_at, heartbeat_at from session_lock where key = 'lock'") do
    return {
      owner_pid = row.owner_pid as integer,
      started_at = row.started_at as integer,
      heartbeat_at = row.heartbeat_at as integer,
    }
  end
  return nil
end

local function is_locked(self: db.DB): boolean, integer
  local info = get_lock_info(self)
  if not info then return false, nil end

  local now = math.floor((ctime.now())) as integer
  local age = now - info.heartbeat_at
  if age > STALE_THRESHOLD then return false, info.owner_pid end

  local my_pid = proc.getpid()
  if info.owner_pid == my_pid then return false, nil end

  local process_exists = signal.kill(info.owner_pid, 0)
  if not process_exists then return false, info.owner_pid end

  return true, info.owner_pid
end

local function try_acquire_lock(self: db.DB): boolean, string
  local now = math.floor((ctime.now())) as integer
  local my_pid = proc.getpid()
  local info = get_lock_info(self)

  if info then
    if info.owner_pid == my_pid then
      self._db:exec("update session_lock set heartbeat_at = ? where key = 'lock'", now)
      return true, nil
    end
    local age = now - info.heartbeat_at
    local process_dead = not signal.kill(info.owner_pid, 0)
    if age > STALE_THRESHOLD or process_dead then
      local ok, err = self._db:exec(
        "update session_lock set owner_pid = ?, started_at = ?, heartbeat_at = ? where key = 'lock'",
        my_pid, now, now)
      if not ok then return false, "failed to claim stale lock: " .. (err or "") end
      return true, nil
    end
    return false, "session locked by pid " .. info.owner_pid
  end

  local ok, err = self._db:exec(
    "insert into session_lock (key, owner_pid, started_at, heartbeat_at) values ('lock', ?, ?, ?)",
    my_pid, now, now)
  if not ok then return false, "failed to create lock: " .. (err or "") end
  return true, nil
end

local function release_lock(self: db.DB): boolean
  local my_pid = proc.getpid()
  local info = get_lock_info(self)
  if info and info.owner_pid == my_pid then
    self._db:exec("delete from session_lock where key = 'lock'")
    return true
  end
  return false
end

local function update_heartbeat(self: db.DB): boolean
  local now = math.floor((ctime.now())) as integer
  local my_pid = proc.getpid()
  local ok = self._db:exec(
    "update session_lock set heartbeat_at = ? where key = 'lock' and owner_pid = ?",
    now, my_pid)
  return ok
end

-- Queue management (conversation-scoped)

local function add_queue_message(self: db.DB, conversation_id: string, message_type: string, content: string): QueueMessage
  local id = ulid.generate()
  local now = math.floor((ctime.now())) as integer
  self._db:exec_list(
    "insert into queue_messages (id, conversation_id, message_type, content, created_at) values (?, ?, ?, ?, ?)",
    {id, conversation_id, message_type, content, now}, 5)
  return {id = id, conversation_id = conversation_id, message_type = message_type, content = content, created_at = now}
end

local function add_steer(self: db.DB, conversation_id: string, content: string): QueueMessage
  return add_queue_message(self, conversation_id, "steer", content)
end

local function add_followup(self: db.DB, conversation_id: string, content: string): QueueMessage
  return add_queue_message(self, conversation_id, "followup", content)
end

local function drain_queue(self: db.DB, conversation_id: string, message_type: string): {QueueMessage}
  local messages: {QueueMessage} = {}
  local now = math.floor((ctime.now())) as integer

  local ok = db.begin_transaction(self)
  if not ok then return messages end

  for row in self._db:query([[
    select id, conversation_id, message_type, content, created_at from queue_messages
    where conversation_id = ? and message_type = ? and consumed_at is null
    order by rowid asc
  ]], conversation_id, message_type) do
    table.insert(messages, row as QueueMessage)
  end

  if #messages > 0 then
    self._db:exec(
      "update queue_messages set consumed_at = ? where conversation_id = ? and message_type = ? and consumed_at is null",
      now, conversation_id, message_type)
  end

  if not db.commit(self) then db.rollback(self) end
  return messages
end

local function drain_steering(self: db.DB, conversation_id: string): {QueueMessage}
  return drain_queue(self, conversation_id, "steer")
end

local function drain_followup(self: db.DB, conversation_id: string): {QueueMessage}
  return drain_queue(self, conversation_id, "followup")
end

local function pending_count(self: db.DB, conversation_id: string, message_type?: string): integer
  if message_type then
    for row in self._db:query("select count(*) as cnt from queue_messages where conversation_id = ? and message_type = ? and consumed_at is null", conversation_id, message_type) do
      return (row.cnt or 0) as integer
    end
  else
    for row in self._db:query("select count(*) as cnt from queue_messages where conversation_id = ? and consumed_at is null", conversation_id) do
      return (row.cnt or 0) as integer
    end
  end
  return 0
end

return {
  -- Lock operations
  try_acquire_lock = try_acquire_lock,
  release_lock = release_lock,
  update_heartbeat = update_heartbeat,
  is_locked = is_locked,
  get_lock_info = get_lock_info,

  -- Queue operations
  add_queue_message = add_queue_message,
  add_steer = add_steer,
  add_followup = add_followup,
  drain_queue = drain_queue,
  drain_steering = drain_steering,
  drain_followup = drain_followup,
  pending_count = pending_count,

  -- Types
  QueueMessage = QueueMessage,
  LockInfo = LockInfo,

  -- Constants
  STALE_THRESHOLD = STALE_THRESHOLD,
}
